/*
 * Copyright (c) 2016-present Invertase Limited & Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this library except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

import 'dart:async';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart';
import 'package:pool/pool.dart';

import 'git.dart';
import 'package.dart';
import 'pub_dependency_list.dart';
import 'utils.dart' as utils;
import 'workspace_config.dart';

MelosWorkspace currentWorkspace;

/// A representation of a workspace. This includes it's packages, configuration
/// such as scripts and more.
class MelosWorkspace {
  MelosWorkspace._(this.name, this.path, this.config);

  /// An optional name as defined in "melos.yaml". This name is used for logging
  /// purposes and also used when generating certain IDE files.
  final String name;

  /// Full file path to the location of this workspace.
  final String path;

  /// Configuration as defined in the "melos.yaml" file if it exists.
  final MelosWorkspaceConfig config;

  /// A list of all the packages detected in this workspace, after being filtered.
  List<MelosPackage> packages;

  /// The same as [packages] but excludes the "scope" filter. This is useful
  /// for commands such as "version" to know about other dependent packages that
  /// may need updating.
  List<MelosPackage> packagesNoScope;

  // Cached dependency graph for perf reasons.
  Map<String, Set<String>> _cacheDependencyGraph;

  /// Build a [MelosWorkspace] from a Directory.
  /// If the directory is not a valid Melos workspace (e.g. no "melos.yaml" file)
  /// then null is returned.
  static Future<MelosWorkspace> fromDirectory(Directory directory) async {
    final workspaceConfig = await MelosWorkspaceConfig.fromDirectory(directory);
    if (workspaceConfig == null) {
      return null;
    }

    return MelosWorkspace._(
        workspaceConfig.name, workspaceConfig.path, workspaceConfig);
  }

  /// Returns true if this workspace contains ANY Flutter package.
  bool get isFlutterWorkspace {
    return packages.firstWhere((package) => package.isFlutterPackage,
            orElse: () => null) !=
        null;
  }

  /// Returns a string path to the '.melos_tool' directory in this workspace.
  /// This directory should be git ignored and is used by Melos for temporary tasks
  /// such as pub install.
  String get melosToolPath {
    return joinAll([path, '.melos_tool']);
  }

  /// Detect specific packages by name in the current workspace.
  /// This behaviour is used in conjunction with the `MELOS_PACKAGES`
  /// environment variable.
  Future<List<MelosPackage>> loadPackagesWithNames(
      List<String> packageNames) async {
    if (packages != null) return Future.value(packages);
    final packagePatterns = config.packages;

    var filterResult =
        Directory(path).list(recursive: true, followLinks: false).where((file) {
      return file.path.endsWith('pubspec.yaml');
    }).where((file) {
      // Filter matching 'packages' config from melos.yaml
      // No 'package' glob patterns in 'melos.yaml' so skip all packages.
      if (packagePatterns.isEmpty) return false;
      final matchedPattern = packagePatterns.firstWhere((pattern) {
        return Glob(pattern).matches(file.path);
      }, orElse: () => null);
      return matchedPattern != null;
    }).asyncMap((entity) {
      // Convert into Package for further filtering
      return MelosPackage.fromPubspecPathAndWorkspace(entity, this);
    });

    filterResult = filterResult.where((package) {
      return packageNames.contains(package.name);
    });

    return packages = await filterResult.toList();
  }

  /// Detect packages in the workspace with the provided filters.
  /// This is the default packages behaviour when a workspace is loaded.
  Future<List<MelosPackage>> loadPackagesWithFilters({
    List<String> scope,
    List<String> ignore,
    String since,
    List<String> dirExists,
    List<String> fileExists,
    bool skipPrivate,
    bool published,
    bool nullsafety,
    bool hasFlutter,
    List<String> dependsOn,
    List<String> noDependsOn,
  }) async {
    if (packages != null) return Future.value(packages);
    final packagePatterns = config.packages;

    var filterResult =
        Directory(path).list(recursive: true, followLinks: false).where((file) {
      return file.path.endsWith('pubspec.yaml');
    }).where((file) {
      // Filter matching 'packages' config from melos.yaml
      // No 'package' glob patterns in 'melos.yaml' so skip all packages.
      if (packagePatterns.isEmpty) return false;
      final matchedPattern = packagePatterns.firstWhere((pattern) {
        return Glob(pattern).matches(file.path);
      }, orElse: () => null);
      return matchedPattern != null;
    }).asyncMap((entity) {
      // Convert into Package for further filtering
      return MelosPackage.fromPubspecPathAndWorkspace(entity, this);
    });

    if (ignore.isNotEmpty) {
      // Ignore packages filter.
      filterResult = filterResult.where((package) {
        final matchedPattern = ignore.firstWhere((pattern) {
          return Glob(pattern).matches(package.name);
        }, orElse: () => null);
        return matchedPattern == null;
      });
    }

    if (dirExists.isNotEmpty) {
      // Directory exists packages filter, multiple filters behaviour is 'AND'.
      filterResult = filterResult.where((package) {
        final dirExistsMatched = dirExists.where((dirExistsPath) {
          return Directory(join(package.path, dirExistsPath)).existsSync();
        });
        return dirExistsMatched.length == dirExists.length;
      });
    }

    if (fileExists.isNotEmpty) {
      // File exists packages filter.
      filterResult = filterResult.where((package) {
        final fileExistsMatched = fileExists.firstWhere((fileExistsPath) {
          final _fileExistsPath =
              fileExistsPath.replaceAll(r'$MELOS_PACKAGE_NAME', package.name);
          return File(join(package.path, _fileExistsPath)).existsSync();
        }, orElse: () => null);
        return fileExistsMatched != null;
      });
    }

    if (skipPrivate == true) {
      // Whether we should skip packages with 'publish_to: none' set.
      filterResult = filterResult.where((package) {
        return !package.isPrivate;
      });
    }

    packages = await filterResult.toList();

    // --published / --no-published
    if (published != null) {
      final pool = Pool(10);
      final packagesFilteredWithPublishStatus = <MelosPackage>[];
      await pool.forEach<MelosPackage, void>(packages, (package) {
        return package.getPublishedVersions().then((versions) async {
          final isOnPubRegistry = versions.contains(package.version);
          if (published == false && !isOnPubRegistry) {
            return packagesFilteredWithPublishStatus.add(package);
          }
          if (published == true && isOnPubRegistry) {
            return packagesFilteredWithPublishStatus.add(package);
          }
        });
      }).drain();
      packages = packagesFilteredWithPublishStatus;
    }

    // --since
    if (since != null) {
      final pool = Pool(10);
      final packagesFilteredWithGitCommitsSince = <MelosPackage>[];
      await pool.forEach<MelosPackage, void>(packages, (package) {
        return gitCommitsForPackage(package, since: since)
            .then((commits) async {
          if (commits.isNotEmpty) {
            packagesFilteredWithGitCommitsSince.add(package);
          }
        });
      }).drain();
      packages = packagesFilteredWithGitCommitsSince;
    }

    packages.sort((a, b) {
      return a.name.compareTo(b.name);
    });

    // We filter scopes and nullsafety last so we can keep a track of packages prior to these filters,
    // this is used for melos version to bump dependant package versions without filtering them out.
    if (scope.isNotEmpty) {
      packagesNoScope = List.from(packages);
      // Scoped packages filter.
      packages = packages.where((package) {
        final matchedPattern = scope.firstWhere((pattern) {
          return Glob(pattern).matches(package.name);
        }, orElse: () => null);
        return matchedPattern != null;
      }).toList();
    } else {
      packagesNoScope = packages;
    }

    // --nullsafety / --no-nullsafety
    if (nullsafety != null) {
      packages = packages.where((package) {
        final isNullsafetyVersion = package.version.isPreRelease &&
            package.version.preRelease.contains('nullsafety');
        if (nullsafety == false && !isNullsafetyVersion) {
          return true;
        }
        if (nullsafety == true && isNullsafetyVersion) {
          return true;
        }
        return false;
      }).toList();
    }

    // --flutter / --no-flutter
    if (hasFlutter != null) {
      if (hasFlutter) {
        dependsOn.add('flutter');
      } else {
        noDependsOn.add('flutter');
      }
    }

    // --depends-on
    if (dependsOn.isNotEmpty) {
      packages = packages.where((package) {
        return dependsOn.every((element) {
          return package.dependencies.containsKey(element) ||
              package.devDependencies.containsKey(element);
        });
      }).toList();
    }

    // --no-depends-on
    if (noDependsOn.isNotEmpty) {
      packages = packages.where((package) {
        return noDependsOn.every((element) {
          return !package.dependencies.containsKey(element) &&
              !package.devDependencies.containsKey(element);
        });
      }).toList();
    }

    return packages;
  }

  /// Builds a dependency graph of dependencies and their dependents in this workspace.
  Future<Map<String, Set<String>>> getDependencyGraph() async {
    if (_cacheDependencyGraph != null) {
      return _cacheDependencyGraph;
    }

    final pubDepsExecArgs = ['--style=list', '--dev'];
    final pubListCommandOutput = await Process.run(
      isFlutterWorkspace
          ? 'flutter'
          : utils.isPubSubcommand()
              ? 'dart'
              : 'pub',
      isFlutterWorkspace
          ? ['pub', 'deps', '--', ...pubDepsExecArgs]
          : [if (utils.isPubSubcommand()) 'pub', 'deps', ...pubDepsExecArgs],
      runInShell: true,
      workingDirectory: melosToolPath,
    );

    final pubDepList =
        PubDependencyList.parse(pubListCommandOutput.stdout as String);
    final allEntries = pubDepList.allEntries;
    final allEntriesMap = allEntries.map((entry, map) {
      return MapEntry(entry.name, map);
    });

    void addNestedEntries(Set entriesSet) {
      final countBefore = entriesSet.length;
      final entriesSetClone = Set.from(entriesSet);
      for (final entryName in entriesSetClone) {
        final depsForEntry = allEntriesMap[entryName];
        if (depsForEntry != null && depsForEntry.isNotEmpty) {
          depsForEntry.forEach((dependentName, _) {
            entriesSet.add(dependentName);
          });
        }
      }
      // We check if the set has grown since we may need gather nested entries
      // from newly discovered dependencies.
      if (countBefore != entriesSet.length) {
        addNestedEntries(entriesSet);
      }
    }

    final dependencyGraphFlat = <String, Set<String>>{};

    allEntries.forEach((entry, dependencies) {
      final entriesSet = <String>{};
      if (dependencies.isNotEmpty) {
        dependencies.forEach((dependentName, _) {
          entriesSet.add(dependentName);
        });
      }
      addNestedEntries(entriesSet);
      dependencyGraphFlat[entry.name] = entriesSet;
    });

    return _cacheDependencyGraph = dependencyGraphFlat;
  }

  /// Execute a command in the root of this workspace.
  Future<int> exec(List<String> execArgs, {bool onlyOutputOnError = false}) {
    final environment = {
      'MELOS_ROOT_PATH': path,
    };

    return utils.startProcess(execArgs,
        environment: environment,
        workingDirectory: path,
        onlyOutputOnError: onlyOutputOnError);
  }

  /// Execute a command in the .melos_tool directory of this workspace.
  Future<int> execInMelosToolPath(List<String> execArgs,
      {bool onlyOutputOnError = false}) {
    final environment = {
      'MELOS_ROOT_PATH': path,
    };

    return utils.startProcess(execArgs,
        environment: environment,
        workingDirectory: melosToolPath,
        onlyOutputOnError: onlyOutputOnError);
  }

  /// Calls [linkPackages] on each [MelosPackage].
  Future<void> linkPackages() async {
    await Future.forEach(packages, (MelosPackage package) {
      return package.linkPackages(this);
    });
  }

  /// Cleans the workspace of all files generated by Melos.
  void clean({bool cleanPackages = true}) {
    if (Directory(melosToolPath).existsSync()) {
      Directory(melosToolPath).deleteSync(recursive: true);
    }
    if (cleanPackages) {
      for (final package in packages) {
        package.clean();
      }
    }
  }
}
