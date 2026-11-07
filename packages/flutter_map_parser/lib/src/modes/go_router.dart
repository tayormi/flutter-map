import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_map_parser/src/const_strings.dart';
import 'package:flutter_map_parser/src/model.dart';
import 'package:path/path.dart' as p;

/// Parses imperative `GoRouter(...)` trees into route nodes and layouts.
class GoRouterParseResult {
  const GoRouterParseResult({
    required this.routes,
    required this.layouts,
    required this.routerFile,
  });

  final List<RouteNode> routes;
  final List<LayoutNode> layouts;
  final String? routerFile;
}

GoRouterParseResult parseGoRouterProject(String projectRoot) {
  final List<String> dartFiles = Directory(p.join(projectRoot, 'lib'))
      .listSync(recursive: true)
      .whereType<File>()
      .where((File file) => file.path.endsWith('.dart'))
      .map((File file) => file.path)
      .toList();
  final Map<String, String> sources = <String, String>{
    for (final String filePath in dartFiles)
      filePath: File(filePath).readAsStringSync(),
  };
  final Map<String, CompilationUnit> units = <String, CompilationUnit>{};
  CompilationUnit unitFor(String filePath) => units.putIfAbsent(
        filePath,
        () => parseString(
          content: sources[filePath]!,
          path: filePath,
          featureSet: FeatureSet.latestLanguageVersion(),
          throwIfDiagnostics: false,
        ).unit,
      );
  final List<String> routeFiles = dartFiles
      .where((String filePath) =>
          sources[filePath]!.contains('GoRoute(') ||
          sources[filePath]!.contains('RouteBase'))
      .toList();
  final List<String> constFiles = dartFiles
      .where((String filePath) =>
          RegExp(r'static\s+const').hasMatch(sources[filePath]!))
      .toList();
  for (final String filePath in dartFiles) {
    final String source = sources[filePath]!;
    if (!source.contains('GoRouter(')) {
      continue;
    }
    final CompilationUnit unit = unitFor(filePath);
    final _GoRouterCollector collector = _GoRouterCollector(
      projectRoot: projectRoot,
      filePath: filePath,
      source: source,
      unit: unit,
      constStrings: ConstStringTable.fromUnits(<CompilationUnit>[
        unit,
        for (final String other in constFiles)
          if (other != filePath) unitFor(other),
      ]),
      routeUnits: <CompilationUnit>[
        for (final String other in routeFiles)
          if (other != filePath) unitFor(other),
      ],
    );
    unit.visitChildren(collector);
    if (collector.routes.isNotEmpty) {
      return GoRouterParseResult(
        routes: collector.routes,
        layouts: collector.layouts,
        routerFile:
            p.relative(filePath, from: projectRoot).split(r'\').join('/'),
      );
    }
  }
  return const GoRouterParseResult(
    routes: <RouteNode>[],
    layouts: <LayoutNode>[],
    routerFile: null,
  );
}

class _GoRouterCollector extends RecursiveAstVisitor<void> {
  _GoRouterCollector({
    required this.projectRoot,
    required this.filePath,
    required this.source,
    required this.unit,
    required this.constStrings,
    this.routeUnits = const <CompilationUnit>[],
  });

  final String projectRoot;
  final String filePath;
  final String source;
  final CompilationUnit unit;
  final ConstStringTable constStrings;
  final List<CompilationUnit> routeUnits;
  final List<RouteNode> routes = <RouteNode>[];
  final List<LayoutNode> layouts = <LayoutNode>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final String name = node.constructorName.type.name2.lexeme;
    _maybeCollectGoRouter(name, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final String name = node.methodName.name;
    if (name == 'GoRouter' ||
        name == 'GoRoute' ||
        name == 'ShellRoute' ||
        name == 'StatefulShellRoute') {
      _maybeCollectGoRouter(name, node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  void _maybeCollectGoRouter(String name, ArgumentList argumentList) {
    if (name != 'GoRouter') {
      return;
    }
    if (routes.isNotEmpty) {
      return;
    }
    final Expression? routesArg = _namedArg(argumentList, 'routes');
    if (routesArg == null) {
      return;
    }
    _walkRoutes(routesArg, parentPath: '');
  }

  void _walkRoutes(Expression expression, {required String parentPath}) {
    final Expression resolved =
        _resolveRoutesExpression(expression) ?? expression;
    final ListLiteral? list = _asList(resolved);
    if (list == null) {
      return;
    }
    for (final CollectionElement element in list.elements) {
      if (element is SpreadElement) {
        _walkRoutes(element.expression, parentPath: parentPath);
        continue;
      }
      if (element is! Expression) {
        continue;
      }
      final _RouteCall? call = _asRouteCall(element);
      if (call == null) {
        continue;
      }
      if (call.name == 'ShellRoute' || call.name == 'StatefulShellRoute') {
        final String navigator =
            call.name == 'StatefulShellRoute' ? 'tabs' : 'shell';
        final String layoutFile =
            p.relative(filePath, from: projectRoot).split(r'\').join('/');
        layouts.add(
          LayoutNode(
            file: layoutFile,
            dir: parentPath.isEmpty ? '' : parentPath,
            navigator: navigator,
          ),
        );
        final Expression? nested = _namedArg(call.argumentList, 'routes');
        if (nested != null) {
          _walkRoutes(nested, parentPath: parentPath);
        }
        final Expression? branches = _namedArg(call.argumentList, 'branches');
        if (branches != null) {
          _walkBranches(branches, parentPath: parentPath);
        }
        continue;
      }
      if (call.name != 'GoRoute') {
        continue;
      }
      final String? rawPath = _resolveStringArg(call.argumentList, 'path');
      if (rawPath == null) {
        continue;
      }
      final String absolutePath = _joinPaths(parentPath, rawPath);
      final String? nameArg = _resolveStringArg(call.argumentList, 'name');
      final String id = nameArg ?? _slugFromPath(absolutePath);
      final List<String> params = _paramsFromPath(absolutePath);
      final String? widgetType = _extractWidgetTypeName(
        _namedArg(call.argumentList, 'builder') ??
            _namedArg(call.argumentList, 'pageBuilder'),
      );
      final String? widgetFile =
          widgetType == null ? null : _findWidgetFile(widgetType);
      final String relativeFile = widgetFile == null
          ? p.relative(filePath, from: projectRoot).split(r'\').join('/')
          : p.relative(widgetFile, from: projectRoot).split(r'\').join('/');
      final String? navigator =
          layouts.isEmpty ? 'stack' : layouts.last.navigator;
      routes.add(
        RouteNode(
          id: id,
          urlPath: absolutePath.isEmpty ? '/' : absolutePath,
          file: relativeFile,
          slug: _slugFromPath(absolutePath.isEmpty ? '/' : absolutePath),
          params: params,
          navigator: navigator,
          layoutDir: layouts.isEmpty ? '' : layouts.last.dir,
          presentation: null,
          widgetName: widgetType,
        ),
      );
      final Expression? children = _namedArg(call.argumentList, 'routes');
      if (children != null) {
        _walkRoutes(children, parentPath: absolutePath);
      }
    }
  }

  Expression? _resolveRoutesExpression(Expression expression) {
    if (expression is ListLiteral) {
      return expression;
    }
    if (expression is SimpleIdentifier) {
      return _lookupTopLevelList(expression.name);
    }
    if (expression is PrefixedIdentifier) {
      return _lookupTopLevelList(expression.identifier.name);
    }
    if (expression is PropertyAccess) {
      return _lookupTopLevelList(expression.propertyName.name);
    }
    if (expression is MethodInvocation) {
      return _lookupTopLevelList(expression.methodName.name);
    }
    return null;
  }

  Expression? _lookupTopLevelList(String name) {
    return _lookupInUnit(unit, name, includeClassMembers: true) ??
        routeUnits
            .map((CompilationUnit other) => _lookupInUnit(other, name))
            .whereType<Expression>()
            .firstOrNull;
  }

  Expression? _lookupInUnit(
    CompilationUnit unit,
    String name, {
    bool includeClassMembers = false,
  }) {
    for (final CompilationUnitMember member in unit.declarations) {
      if (includeClassMembers && member is ClassDeclaration) {
        for (final ClassMember classMember in member.members) {
          if (classMember is MethodDeclaration &&
              classMember.name.lexeme == name) {
            final Expression? returned = _returnedExpression(classMember.body);
            if (returned != null) {
              return returned;
            }
          }
          if (classMember is FieldDeclaration) {
            for (final VariableDeclaration variable
                in classMember.fields.variables) {
              if (variable.name.lexeme == name &&
                  variable.initializer != null) {
                return variable.initializer;
              }
            }
          }
        }
      }
      if (member is FunctionDeclaration && member.name.lexeme == name) {
        final FunctionBody body = member.functionExpression.body;
        if (body is ExpressionFunctionBody) {
          return body.expression;
        }
        if (body is BlockFunctionBody) {
          for (final Statement statement in body.block.statements) {
            if (statement is ReturnStatement) {
              return statement.expression;
            }
          }
        }
      }
      if (member is TopLevelVariableDeclaration) {
        for (final VariableDeclaration variable in member.variables.variables) {
          if (variable.name.lexeme == name) {
            return variable.initializer;
          }
        }
      }
    }
    return null;
  }

  Expression? _returnedExpression(FunctionBody body) {
    if (body is ExpressionFunctionBody) {
      return body.expression;
    }
    if (body is BlockFunctionBody) {
      for (final Statement statement in body.block.statements) {
        if (statement is ReturnStatement) {
          return statement.expression;
        }
      }
    }
    return null;
  }

  void _walkBranches(Expression expression, {required String parentPath}) {
    final ListLiteral? list =
        _asList(_resolveRoutesExpression(expression) ?? expression);
    if (list == null) {
      return;
    }
    for (final CollectionElement element in list.elements) {
      if (element is! Expression) {
        continue;
      }
      final _RouteCall? call = _asRouteCall(element);
      if (call == null) {
        continue;
      }
      final Expression? routesArg = _namedArg(call.argumentList, 'routes');
      if (routesArg != null) {
        _walkRoutes(routesArg, parentPath: parentPath);
      }
    }
  }

  String? _resolveStringArg(ArgumentList argumentList, String name) {
    final Expression? expression = _namedArg(argumentList, name);
    if (expression == null) {
      return null;
    }
    return constStrings.resolveExpression(expression) ??
        (expression is SimpleStringLiteral ? expression.value : null) ??
        (expression is AdjacentStrings ? expression.stringValue : null);
  }

  String? _extractWidgetTypeName(Expression? builder) {
    if (builder is FunctionExpression) {
      final FunctionBody body = builder.body;
      Expression? returned;
      if (body is ExpressionFunctionBody) {
        returned = body.expression;
      } else if (body is BlockFunctionBody) {
        for (final Statement statement in body.block.statements) {
          if (statement is ReturnStatement) {
            returned = statement.expression;
            break;
          }
        }
      }
      return _widgetTypeFromExpression(returned);
    }
    return null;
  }

  String? _widgetTypeFromExpression(Expression? expression) {
    if (expression == null) {
      return null;
    }
    if (expression is InstanceCreationExpression) {
      return expression.constructorName.type.name2.lexeme;
    }
    if (expression is MethodInvocation) {
      for (final Expression argument
          in expression.argumentList.arguments.reversed) {
        final Expression unwrapped =
            argument is NamedExpression ? argument.expression : argument;
        final String? nested = _widgetTypeFromExpression(unwrapped);
        if (nested != null &&
            nested != 'CustomTransitionPage' &&
            nested != 'MaterialPage' &&
            nested != 'CupertinoPage') {
          return nested;
        }
      }
      return expression.methodName.name;
    }
    return null;
  }

  String? _findWidgetFile(String typeName) {
    final RegExp classPattern = RegExp('class\\s+$typeName\\b');
    final Directory libDirectory = Directory(p.join(projectRoot, 'lib'));
    if (!libDirectory.existsSync()) {
      return null;
    }
    for (final FileSystemEntity entity
        in libDirectory.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final String content = entity.readAsStringSync();
      if (classPattern.hasMatch(content)) {
        return entity.path;
      }
    }
    return null;
  }
}

class _RouteCall {
  const _RouteCall({
    required this.name,
    required this.argumentList,
  });

  final String name;
  final ArgumentList argumentList;
}

_RouteCall? _asRouteCall(Expression expression) {
  if (expression is InstanceCreationExpression) {
    return _RouteCall(
      name: expression.constructorName.type.name2.lexeme,
      argumentList: expression.argumentList,
    );
  }
  if (expression is MethodInvocation) {
    final Expression? target = expression.target;
    final bool namedConstructor =
        target is SimpleIdentifier && _routeTypeNames.contains(target.name);
    return _RouteCall(
      name: namedConstructor ? target.name : expression.methodName.name,
      argumentList: expression.argumentList,
    );
  }
  return null;
}

const Set<String> _routeTypeNames = <String>{
  'GoRoute',
  'ShellRoute',
  'StatefulShellRoute',
  'StatefulShellBranch',
};

ListLiteral? _asList(Expression expression) {
  if (expression is ListLiteral) {
    return expression;
  }
  return null;
}

Expression? _namedArg(ArgumentList argumentList, String name) {
  for (final Expression argument in argumentList.arguments) {
    if (argument is NamedExpression && argument.name.label.name == name) {
      return argument.expression;
    }
  }
  return null;
}

String _joinPaths(String parent, String child) {
  if (child.startsWith('/')) {
    return child == '/' ? '/' : child;
  }
  if (parent.isEmpty || parent == '/') {
    return '/$child';
  }
  final String normalizedParent =
      parent.endsWith('/') ? parent.substring(0, parent.length - 1) : parent;
  return '$normalizedParent/$child';
}

List<String> _paramsFromPath(String urlPath) {
  return urlPath
      .split('/')
      .where((String segment) => segment.startsWith(':'))
      .map((String segment) => segment.substring(1))
      .toList();
}

String _slugFromPath(String urlPath) {
  if (urlPath == '/' || urlPath.isEmpty) {
    return 'index';
  }
  return urlPath
      .replaceAll(RegExp(r'^/+'), '')
      .replaceAll(':', '')
      .replaceAll('/', '_');
}
