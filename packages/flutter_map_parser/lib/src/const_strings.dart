import 'package:analyzer/dart/ast/ast.dart';

/// Resolves simple compile-time string constants declared in a unit.
class ConstStringTable {
  ConstStringTable(this._values);

  final Map<String, String> _values;

  static ConstStringTable fromUnit(CompilationUnit unit) =>
      fromUnits(<CompilationUnit>[unit]);

  /// Merges constants from several units; earlier units win on bare names.
  static ConstStringTable fromUnits(Iterable<CompilationUnit> units) {
    final Map<String, Expression> pending = <String, Expression>{};
    for (final CompilationUnitMember member
        in units.expand((CompilationUnit unit) => unit.declarations)) {
      if (member is TopLevelVariableDeclaration) {
        _collectVariables(
          member.variables,
          prefix: null,
          pending: pending,
        );
      } else if (member is ClassDeclaration) {
        final String className = member.name.lexeme;
        for (final ClassMember classMember in member.members) {
          if (classMember is FieldDeclaration && classMember.isStatic) {
            _collectVariables(
              classMember.fields,
              prefix: className,
              pending: pending,
            );
          }
        }
      }
    }
    final Map<String, String> resolved = <String, String>{};
    bool progressed = true;
    while (progressed && pending.isNotEmpty) {
      progressed = false;
      final List<String> keys = pending.keys.toList(growable: false);
      for (final String key in keys) {
        final Expression expression = pending[key]!;
        if (expression is RecordLiteral) {
          final bool expanded = _expandRecord(
            key: key,
            record: expression,
            pending: pending,
            resolved: resolved,
          );
          if (expanded) {
            pending.remove(key);
            progressed = true;
          }
          continue;
        }
        final String? value = _evaluate(expression, resolved, key);
        if (value != null) {
          resolved[key] = value;
          pending.remove(key);
          progressed = true;
        }
      }
    }
    return ConstStringTable(resolved);
  }

  String? resolveExpression(Expression expression) {
    return _evaluate(expression, _values, null);
  }

  /// Snapshot of resolved constant keys (`Routes.home`, `AppPaths.eventHub`, …).
  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  static bool _expandRecord({
    required String key,
    required RecordLiteral record,
    required Map<String, Expression> pending,
    required Map<String, String> resolved,
  }) {
    bool allResolved = true;
    for (final Expression field in record.fields) {
      if (field is! NamedExpression) {
        allResolved = false;
        continue;
      }
      final String fieldKey = '$key.${field.name.label.name}';
      final String? value = _evaluate(field.expression, resolved, fieldKey);
      if (value == null) {
        pending[fieldKey] = field.expression;
        allResolved = false;
        continue;
      }
      resolved[fieldKey] = value;
    }
    return allResolved;
  }

  static void _collectVariables(
    VariableDeclarationList variables, {
    required String? prefix,
    required Map<String, Expression> pending,
  }) {
    if (!variables.isConst && !variables.isFinal) {
      return;
    }
    for (final VariableDeclaration variable in variables.variables) {
      final Expression? initializer = variable.initializer;
      if (initializer == null) {
        continue;
      }
      final String name = variable.name.lexeme;
      final String key = prefix == null ? name : '$prefix.$name';
      pending[key] = initializer;
      if (prefix != null) {
        pending.putIfAbsent(name, () => initializer);
      }
    }
  }

  static String? _evaluate(
    Expression expression,
    Map<String, String> known,
    String? currentKey,
  ) {
    if (expression is SimpleStringLiteral) {
      return expression.value;
    }
    if (expression is AdjacentStrings) {
      final StringBuffer buffer = StringBuffer();
      for (final StringLiteral part in expression.strings) {
        final String? value = _evaluate(part, known, currentKey);
        if (value == null) {
          return null;
        }
        buffer.write(value);
      }
      return buffer.toString();
    }
    if (expression is StringInterpolation) {
      final StringBuffer buffer = StringBuffer();
      for (final InterpolationElement element in expression.elements) {
        if (element is InterpolationString) {
          buffer.write(element.value);
          continue;
        }
        if (element is InterpolationExpression) {
          final String? value =
              _evaluate(element.expression, known, currentKey);
          if (value == null) {
            return null;
          }
          buffer.write(value);
        }
      }
      return buffer.toString();
    }
    if (expression is PrefixedIdentifier) {
      final String key =
          '${expression.prefix.name}.${expression.identifier.name}';
      return known[key];
    }
    if (expression is PropertyAccess) {
      final String? key = _propertyAccessKey(expression);
      if (key != null && known.containsKey(key)) {
        return known[key];
      }
    }
    if (expression is SimpleIdentifier) {
      final String name = expression.name;
      if (known.containsKey(name)) {
        return known[name];
      }
      if (currentKey != null && currentKey.contains('.')) {
        final String className = currentKey.split('.').first;
        return known['$className.$name'];
      }
    }
    return null;
  }

  static String? _propertyAccessKey(PropertyAccess expression) {
    final List<String> parts = <String>[expression.propertyName.name];
    Expression? current = expression.target;
    while (current != null) {
      if (current is SimpleIdentifier) {
        parts.add(current.name);
        break;
      }
      if (current is PrefixedIdentifier) {
        parts
          ..add(current.identifier.name)
          ..add(current.prefix.name);
        break;
      }
      if (current is PropertyAccess) {
        parts.add(current.propertyName.name);
        current = current.target;
        continue;
      }
      return null;
    }
    return parts.reversed.join('.');
  }
}
