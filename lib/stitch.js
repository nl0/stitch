// Generated by CoffeeScript 1.3.3
(function() {
  var CoffeeScript, Package, SEPARATOR, compilers, customCompiler, eco, extend, extname, forEach, join, map, parallel, readFile, readFileSync, readdir, realpath, stat, statSync, _ref, _ref1, _ref2,
    __slice = [].slice,
    __bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; };

  _ref = require('fs'), readFileSync = _ref.readFileSync, readFile = _ref.readFile, stat = _ref.stat, statSync = _ref.statSync, realpath = _ref.realpath, readdir = _ref.readdir;

  _ref1 = require('async'), parallel = _ref1.parallel, map = _ref1.map, forEach = _ref1.forEach;

  _ref2 = require('path'), extname = _ref2.extname, join = _ref2.join;

  SEPARATOR = process.platform === 'win32' ? '\\' : '/';

  extend = function() {
    var args, obj;
    obj = arguments[0], args = 2 <= arguments.length ? __slice.call(arguments, 1) : [];
    args.forEach(function(x) {
      var k, v, _results;
      _results = [];
      for (k in x) {
        v = x[k];
        _results.push(obj[k] = v);
      }
      return _results;
    });
    return obj;
  };

  customCompiler = function(fn) {
    return function(module, filename) {
      var content;
      content = fn(readFileSync(filename, 'utf8'));
      return module._compile(content, filename);
    };
  };

  exports.compilers = compilers = {
    js: customCompiler(function(x) {
      return x;
    })
  };

  try {
    CoffeeScript = require('coffee-script');
    compilers.coffee = customCompiler(CoffeeScript.compile);
  } catch (err) {

  }

  try {
    eco = require('eco');
    if (eco.precompile) {
      compilers.eco = customCompiler(function(x) {
        return "module.exports = " + (eco.precompile(x));
      });
    } else {
      compilers.eco = customCompiler(eco.compile);
    }
  } catch (err) {

  }

  exports.Package = Package = (function() {

    function Package(config) {
      this.compileSources = __bind(this.compileSources, this);

      this.compileDependencies = __bind(this.compileDependencies, this);

      var _ref3, _ref4, _ref5, _ref6;
      this.identifier = (_ref3 = config.identifier) != null ? _ref3 : 'require';
      this.paths = (_ref4 = config.paths) != null ? _ref4 : ['lib'];
      this.dependencies = (_ref5 = config.dependencies) != null ? _ref5 : [];
      this.compilers = extend({}, compilers, config.compilers);
      this.cache = (_ref6 = config.cache) != null ? _ref6 : true;
      this.mtimeCache = {};
      this.compileCache = {};
    }

    Package.prototype.compile = function(callback) {
      var done;
      done = function(err, x) {
        if (err) {
          return callback(err);
        } else {
          return callback(null, x.join("\n"));
        }
      };
      return parallel([this.compileDependencies, this.compileSources], done);
    };

    Package.prototype.compileDependencies = function(callback) {
      return map(this.dependencies, readFile, function(err, deps) {
        if (err) {
          return callback(err);
        } else {
          return callback(null, deps.join("\n"));
        }
      });
    };

    Package.prototype.compiledSourceDefinitions = function(callback) {
      var addCompiledSource, compileSourceFile, iterator, sources,
        _this = this;
      sources = {};
      addCompiledSource = function(key, source, next) {
        if (sources[key]) {
          return next(new Error("" + key + " exists more than once in the package"));
        } else {
          sources[key] = source;
          return next(null);
        }
      };
      compileSourceFile = function(path, next) {
        if (!_this.compilers[extname(path).slice(1)]) {
          return next(null);
        }
        return _this.getRelativePath(path, function(err, relativePath) {
          if (err) {
            return next(err);
          }
          return _this.compileFile(path, function(err, source) {
            var key;
            if (err) {
              return next(err);
            }
            key = relativePath.slice(0, -extname(relativePath).length);
            return addCompiledSource(key, source, next);
          });
        });
      };
      iterator = function(path, next) {
        return stat(path, function(err, stat) {
          if (err) {
            return next(err);
          }
          if (stat.isDirectory()) {
            return _this.getFilesInTree(path, function(err, paths) {
              if (err) {
                return next(err);
              }
              return forEach(paths, compileSourceFile, next);
            });
          } else {
            return compileSourceFile(path, next);
          }
        });
      };
      return forEach(this.paths, iterator, function(err) {
        var func, modules, name, source;
        if (err) {
          return callback(err);
        }
        modules = (function() {
          var _results;
          _results = [];
          for (name in sources) {
            source = sources[name];
            func = ": function(exports, require, module) {" + source + "\n}";
            _results.push([JSON.stringify(name), func].join(""));
          }
          return _results;
        })();
        return callback(null, "{" + (modules.join(",")) + "}");
      });
    };

    Package.prototype.compileSources = function(callback) {
      var _this = this;
      return this.compiledSourceDefinitions(function(err, definitions) {
        var result;
        if (err) {
          callback(err);
        }
        result = "(function(/*! Stitch !*/) {\n  if (!this." + _this.identifier + ") {\n    var modules = {}, cache = {}, require = function(name, root) {\n      var fn, module, path = expand(root, name),\n        altPath = expand(path, './index');\n\n      if (module = cache[path] || cache[altPath]) {\n        return module.exports;\n      } else if (fn = modules[path] || modules[path = altPath]) {\n        module = {id: path, exports: {}};\n        try {\n          cache[path] = module;\n          fn(module.exports, function(name) {\n            return require(name, dirname(path));\n          }, module);\n          return module.exports;\n        } catch (err) {\n          delete cache[path];\n          throw err;\n        }\n      } else {\n        throw 'module \\'' + name + '\\' not found';\n      }\n    }, expand = function(root, name) {\n      var results = [], parts, part;\n      if (/^\\.\\.?(\\/|$)/.test(name)) {\n        parts = [root, name].join('/').split('/');\n      } else {\n        parts = name.split('/');\n      }\n      for (var i = 0, length = parts.length; i < length; i++) {\n        part = parts[i];\n        if (part == '..') {\n          results.pop();\n        } else if (part != '.' && part != '') {\n          results.push(part);\n        }\n      }\n      return results.join('/');\n    }, dirname = function(path) {\n      return path.split('/').slice(0, -1).join('/');\n    };\n    this." + _this.identifier + " = function(name) {\n      return require(name, '');\n    }\n    this." + _this.identifier + ".define = function(bundle) {\n      for (var key in bundle)\n        modules[key] = bundle[key];\n    };\n  }\n  return this." + _this.identifier + ".define;\n}).call(this)(" + definitions + ");\n";
        return callback(err, result);
      });
    };

    Package.prototype.createServer = function() {
      var _this = this;
      return function(req, res, next) {
        return _this.compile(function(err, source) {
          var message;
          if (err) {
            console.error("" + err.stack);
            message = "" + err.stack;
            res.writeHead(500, {
              'Content-Type': 'text/javascript'
            });
            return res.end("throw " + (JSON.stringify(message)));
          } else {
            res.writeHead(200, {
              'Content-Type': 'text/javascript'
            });
            return res.end(source);
          }
        });
      };
    };

    Package.prototype.getRelativePath = function(path, callback) {
      var _this = this;
      return realpath(path, function(err, sourcePath) {
        if (err) {
          return callback(err);
        }
        return map(_this.paths, realpath, function(err, expandedPaths) {
          var base, expandedPath, relativePath, _i, _len;
          if (err) {
            return callback(err);
          }
          for (_i = 0, _len = expandedPaths.length; _i < _len; _i++) {
            expandedPath = expandedPaths[_i];
            base = expandedPath;
            if (statSync(expandedPath).isDirectory()) {
              base += SEPARATOR;
            }
            if (sourcePath.indexOf(base) === 0) {
              relativePath = sourcePath.slice(base.length).replace(/\\/g, "/");
              return callback(null, relativePath);
            }
          }
          return callback(new Error("" + path + " isn't in the require path"));
        });
      });
    };

    Package.prototype.compileFile = function(path, callback) {
      var compile, extension, mod, mtime, source;
      extension = extname(path).slice(1);
      if (this.cache && this.compileCache[path] && this.mtimeCache[path] === this.compileCache[path].mtime) {
        return callback(null, this.compileCache[path].source);
      } else if (compile = this.compilers[extension]) {
        source = null;
        mod = {
          _compile: function(content, filename) {
            return source = content;
          }
        };
        try {
          compile(mod, path);
          if (this.cache && (mtime = this.mtimeCache[path])) {
            this.compileCache[path] = {
              mtime: mtime,
              source: source
            };
          }
          return callback(null, source);
        } catch (err) {
          if (err instanceof Error) {
            err.message = "can't compile " + path + "\n" + err.message;
          } else {
            err = new Error("can't compile " + path + "\n" + err);
          }
          return callback(err);
        }
      } else {
        return callback(new Error("no compiler for '." + extension + "' files"));
      }
    };

    Package.prototype.getFilesInTree = function(directory, cb) {
      var files, finalizer, iterator;
      files = [];
      iterator = function(file) {
        return files.push(file);
      };
      finalizer = function(err) {
        if (err) {
          return cb(err);
        } else {
          return cb(null, files.sort());
        }
      };
      return this.walkTree(directory, iterator, finalizer);
    };

    Package.prototype.walkTree = function(directory, iterator, finalizer) {
      var _this = this;
      return readdir(directory, function(err, files) {
        var iter;
        if (err) {
          return finalizer(err);
        }
        iter = function(file, next) {
          var filename;
          if (file.match(/^\./)) {
            return next();
          }
          filename = join(directory, file);
          return stat(filename, function(err, stats) {
            if (err) {
              return next(err);
            }
            _this.mtimeCache[filename] = stats.mtime.toString();
            if (stats.isDirectory()) {
              return _this.walkTree(filename, iterator, next);
            } else {
              iterator(filename);
              return next();
            }
          });
        };
        return forEach(files, iter, finalizer);
      });
    };

    return Package;

  })();

  exports.middleware = require('./middleware');

  exports.createPackage = function(config) {
    return new Package(config);
  };

}).call(this);
