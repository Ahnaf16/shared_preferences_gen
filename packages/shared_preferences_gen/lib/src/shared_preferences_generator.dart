import 'dart:async';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:shared_preferences_annotation/shared_preferences_annotation.dart';
import 'package:shared_preferences_gen/src/exceptions/exceptions.dart';
import 'package:shared_preferences_gen/src/templates/gen_template.dart';
import 'package:shared_preferences_gen/src/utils/shared_pref_entry_utils.dart';
import 'package:source_gen/source_gen.dart';
import 'package:source_helper/source_helper.dart';

const _annotations = <Type>{SharedPrefData};

const _spBaseTypes = <String>{'String', 'int', 'double', 'bool', 'List<String>'};

class SharedPreferencesGenerator extends Generator {
  const SharedPreferencesGenerator();

  TypeChecker get _typeChecker => TypeChecker.any(_annotations.map((e) => TypeChecker.fromRuntime(e)));

  @override
  Future<String> generate(LibraryReader library, BuildStep buildStep) async {
    final getters = <String>{};
    final converters = <String>{};
    final keys = <String>{};

    _generateForAnnotation(library: library, getters: getters, converters: converters, keys: keys);

    if (getters.isEmpty) return '';

    return [
      '''
extension \$SharedPreferencesGenX on SharedPreferences {
  ${keys.isNotEmpty ? 'Set<$spValueGenClassName> get entries => {${keys.join(', ')}};' : ''}

  ${getters.map((getter) => getter).join('\n')}
}
    ''',
      ...converters,
    ].join('\n\n');
  }

  void _generateForAnnotation({
    required LibraryReader library,
    required Set<String> getters,
    required Set<String> converters,
    required Set<String> keys,
  }) {
    for (final annotatedElement in library.annotatedWith(_typeChecker)) {
      final generatedValue = _generateForAnnotatedElement(annotatedElement.element, annotatedElement.annotation);

      for (final value in generatedValue) {
        switch (value) {
          case GetterTemplate():
            getters.add(value.build());
            final added = keys.add(value.key);
            if (!added) throw DuplicateKeyException(value.key);
          case EnumTemplate():
            converters.add(value.build());
        }
      }
    }
  }

  Iterable<GenTemplate> _generateForAnnotatedElement(Element element, ConstantReader annotation) sync* {
    final entries = annotation.peek('entries')?.listValue ?? [];

    for (final entry in entries) {
      final reader = ConstantReader(entry);

      // Generic type check
      final dartType = reader.objectValue.type;
      final (:output, :input) = _extractGenericTypes(dartType!);

      // Properties
      final entryObj = entryForObject(entry);
      final adapter = _extractAdapter(dartType, reader);

      yield GetterTemplate(
        key: entryObj.key,
        isEnum: dartType.isEnumEntry,
        isSerializable: dartType.isSerializableEntry,
        accessor: entryObj.accessor,
        adapter: adapter,
        defaultValue: entryObj.defaultValue,
        defaultValueAsString: entryObj.defaultValueAsString,
        inputType: input,
        outputType: output,
      );

      if (dartType.isEnumEntry) yield EnumTemplate(enumType: output);
    }
  }

  ({String input, String output}) _extractGenericTypes(DartType dartType) {
    final typeName = dartType.typeName;

    return switch ((typeName, dartType)) {
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final typeArg])) when typeArg.isSupportedBaseType => (
        input: typeArg.fullTypeName,
        output: typeArg.fullTypeName,
      ),
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final typeArg])) when typeArg.isDateTime => (
        input: 'int',
        output: typeArg.fullTypeName,
      ),
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final typeArg])) when typeArg.isEnum => (
        input: 'int',
        output: typeArg.fullTypeName,
      ),
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final typeArg])) when typeArg.isSerializable => (
        input: 'String',
        output: typeArg.fullTypeName,
      ),
      ('CustomEntry', ParameterizedType(typeArguments: [final outputType, final inputType])) => (
        input: inputType.fullTypeName,
        output: outputType.fullTypeName,
      ),
      _ => throw UnsupportedSharedPrefEntryValueType(dartType.fullTypeName),
    };
  }

  String? _extractAdapter(DartType dartType, ConstantReader reader) {
    final adapterField = reader.peek('adapter')?.objectValue.type?.fullTypeName;
    if (adapterField != null) return adapterField;

    final typeName = dartType.typeName;
    return switch ((typeName, dartType)) {
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final argType])) when argType.isDateTime =>
        dateTimeMillisecondAdapterClassName,
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final enumType])) when enumType.isEnum =>
        '$enumIndexAdapterClassName<$enumType>',
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final argType])) when argType.isSerializable =>
        '$serializableAdapterClassName<$argType>',
      _ => null,
    };
  }
}

extension on String {
  /// Remove generic types from a string. (e.g. `List<String>` -> `List`)
  String removeGenericTypes() {
    final regex = RegExp(r'<.*>');
    return replaceAll(regex, '');
  }
}

extension on DartType {
  bool get isSupportedBaseType => _spBaseTypes.contains(fullTypeName);

  bool get isEnumEntry {
    return switch ((typeName, this)) {
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final arg])) => arg.isEnum,
      _ => false,
    };
  }

  bool get isSerializableEntry {
    return switch ((typeName, this)) {
      ('SharedPrefEntry', ParameterizedType(typeArguments: [final arg])) => arg.isSerializable,
      _ => false,
    };
  }

  bool get isDateTime => fullTypeName == 'DateTime';

  bool get isSerializable {
    final classElement = element3;
    if (classElement is! ClassElement2) return false;

    final hasToJsonMethod =
        classElement.lookUpMethod2(name: 'toJson', library: classElement.library2) != null ||
        classElement.mixins.any((mixin) => mixin.lookUpMethod3('toJson', classElement.library2) != null);

    final hasToMapMethod =
        classElement.lookUpMethod2(name: 'toMap', library: classElement.library2) != null ||
        classElement.mixins.any((mixin) => mixin.lookUpMethod3('toMap', classElement.library2) != null);

    if (!hasToJsonMethod && !hasToMapMethod) return false;

    return classElement.constructors2.any((e) => e.name3 == 'fromJson' || e.name3 == 'fromMap');
  }

  String get fullTypeName => getDisplayString();
  String get typeName => fullTypeName.removeGenericTypes();
}
