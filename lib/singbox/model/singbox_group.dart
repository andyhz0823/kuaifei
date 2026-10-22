import 'package:freezed_annotation/freezed_annotation.dart';

part 'singbox_group.freezed.dart';
part 'singbox_group.g.dart';

/// 用户自定义策略组。字段与 core 侧 SplitGroup 对齐（kebab-case）。
@freezed
class SingboxGroup with _$SingboxGroup {
  const SingboxGroup._();

  @JsonSerializable(fieldRename: FieldRename.kebab)
  const factory SingboxGroup({
    required String name,
    @Default('selector') String type,
    @Default([]) List<String> outbounds,
  }) = _SingboxGroup;

  factory SingboxGroup.fromJson(Map<String, dynamic> json) => _$SingboxGroupFromJson(json);
}
