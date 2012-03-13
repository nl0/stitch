_     = require 'underscore'
async = require 'async'
fs    = require 'fs'

{extname, join, normalize} = require 'path'



# Return a function which wraps the content in a custom compiler. The compiler
# is given the raw file contents (in utf8) and is expected to return the
# compiled source.
customCompiler = (fn) -> (module, filename) ->
    content = fn fs.readFileSync filename, 'utf8'
    module._compile content, filename



# The list of all compilers that we support. Out of the box only pure
# javascript is supported. But if coffee-script or eco are installed we know
# how to compile those as well.
exports.compilers = compilers =
  js: customCompiler (x) -> x


try
  CoffeeScript = require 'coffee-script'
  compilers.coffee = customCompiler CoffeeScript.compile
catch err

try
  eco = require 'eco'
  if eco.precompile
    compilers.eco = customCompiler (x) -> "module.exports = #{eco.precompile x}"
  else
    compilers.eco = customCompiler eco.compile
catch err


exports.Package = class Package
  constructor: (config) ->
    @identifier   = config.identifier ? 'require'
    @paths        = config.paths ? ['lib']
    @dependencies = config.dependencies ? []
    @compilers    = _.extend {}, compilers, config.compilers

    @cache        = config.cache ? true
    @mtimeCache   = {}
    @compileCache = {}


  # Compile the package and invoke the callback with the result. The callback
  # will be given two arguments, (err, source). Source is the compiled package
  # as a string.
  compile: (callback) ->
    async.parallel [
      @compileDependencies
      @compileSources
    ], (err, parts) ->
      if err then callback err
      else callback null, parts.join("\n")


  # Dependencies are treated as plaintext files and are not compiled. They are
  # simply prepended to the result. Note that no particular ordering is
  # guaranteed for those files!
  compileDependencies: (callback) =>
    async.map @dependencies, fs.readFile, (err, deps) ->
      if err then callback(err) else callback null, deps.join "\n"

  compileSources: (callback) =>
    async.reduce @paths, {}, _.bind(@gatherSourcesFromPath, @), (err, sources) =>
      return callback err if err

      result = """
        (function(/*! Stitch !*/) {
          if (!this.#{@identifier}) {
            var modules = {}, cache = {}, require = function(name, root) {
              var path = expand(root, name), module = cache[path], fn;
              if (module) {
                return module.exports;
              } else if (fn = modules[path] || modules[path = expand(path, './index')]) {
                module = {id: path, exports: {}};
                try {
                  cache[path] = module;
                  fn(module.exports, function(name) {
                    return require(name, dirname(path));
                  }, module);
                  return module.exports;
                } catch (err) {
                  delete cache[path];
                  throw err;
                }
              } else {
                throw 'module \\'' + name + '\\' not found';
              }
            }, expand = function(root, name) {
              var results = [], parts, part;
              if (/^\\.\\.?(\\/|$)/.test(name)) {
                parts = [root, name].join('/').split('/');
              } else {
                parts = name.split('/');
              }
              for (var i = 0, length = parts.length; i < length; i++) {
                part = parts[i];
                if (part == '..') {
                  results.pop();
                } else if (part != '.' && part != '') {
                  results.push(part);
                }
              }
              return results.join('/');
            }, dirname = function(path) {
              return path.split('/').slice(0, -1).join('/');
            };
            this.#{@identifier} = function(name) {
              return require(name, '');
            }
            this.#{@identifier}.define = function(bundle) {
              for (var key in bundle)
                modules[key] = bundle[key];
            };
          }
          return this.#{@identifier}.define;
        }).call(this)({
      """

      index = 0
      for name, {filename, source} of sources
        result += if index++ is 0 then "" else ", "
        result += JSON.stringify name
        result += ": function(exports, require, module) {#{source}}"

      result += """
        });\n
      """

      callback err, result

  createServer: ->
    (req, res, next) =>
      @compile (err, source) ->
        if err
          console.error "#{err.stack}"
          message = "" + err.stack
          res.writeHead 500, 'Content-Type': 'text/javascript'
          res.end "throw #{JSON.stringify(message)}"
        else
          res.writeHead 200, 'Content-Type': 'text/javascript'
          res.end source


  gatherSourcesFromPath: (sources, sourcePath, callback) ->
    fs.stat sourcePath, (err, stat) =>
      return callback err if err

      if stat.isDirectory()
        @getFilesInTree sourcePath, (err, paths) =>
          return callback err if err
          async.reduce paths, sources, _.bind(@gatherCompilableSource, @), callback
      else
        @gatherCompilableSource sources, sourcePath, callback

  gatherCompilableSource: (sources, path, callback) ->
    if @compilers[extname(path).slice(1)]
      @getRelativePath path, (err, relativePath) =>
        return callback err if err

        @compileFile path, (err, source) ->
          if err then callback err
          else
            extension = extname relativePath
            key       = relativePath.slice(0, -extension.length)
            sources[key] =
              filename: relativePath
              source:   source
            callback err, sources
    else
      callback null, sources

  getRelativePath: (path, callback) ->
    fs.realpath path, (err, sourcePath) =>
      return callback err if err

      async.map @paths, fs.realpath, (err, expandedPaths) ->
        return callback err if err

        for expandedPath in expandedPaths
          base = expandedPath + "/"
          if sourcePath.indexOf(base) is 0
            return callback null, sourcePath.slice base.length
        callback new Error "#{path} isn't in the require path"


  # Compile the file at `path` and invoke the callback with (err, source),
  # where `source` is the compiled source as string. If enabled through the
  # options, the compiled source is cached.
  compileFile: (path, callback) ->
    extension = extname(path).slice(1)

    if @cache and @compileCache[path] and @mtimeCache[path] is @compileCache[path].mtime
      callback null, @compileCache[path].source
    else if compile = @compilers[extension]
      source = null
      mod =
        _compile: (content, filename) ->
          source = content

      try
        compile mod, path

        if @cache and mtime = @mtimeCache[path]
          @compileCache[path] = {mtime, source}

        callback null, source
      catch err
        if err instanceof Error
          err.message = "can't compile #{path}\n#{err.message}"
        else
          err = new Error "can't compile #{path}\n#{err}"
        callback err
    else
      callback new Error "no compiler for '.#{extension}' files"


  # Recursively walk the directory, invoking the iterator once for each file
  # that is found. If at any point an error is encountered, the finalizer is
  # called with the error in its first argument. If the tree walk completed
  # without errors the finalizer is called with no arguments.
  walkTree: (directory, iterator, finalizer) ->
    fs.readdir directory, (err, files) =>
      return finalizer err if err

      # The function that is called for each dirent. The first argument is the
      # dirent, the second a callback that has to be invoked when the function
      # is finished with its asynchronous operations.
      iter = (file, next) =>
        return next() if file.match /^\./

        filename = join directory, file
        fs.stat filename, (err, stats) =>
          return next err if err

          @mtimeCache[filename] = stats.mtime.toString()

          if stats.isDirectory()
            @walkTree filename, iterator, next
          else
            iterator filename
            next()

      async.forEach files, iter, finalizer


  # Recursivly walk the directory and collect all files. Invoke the callback
  # with (err, files). The files array is sorted.
  getFilesInTree: (directory, cb) ->
    files = []

    iterator  = (file) -> files.push file
    finalizer = (err)  -> if err then cb(err) else cb null, files.sort()

    @walkTree directory, iterator, finalizer



exports.createPackage = (config) ->
  new Package config
