// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'connection.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$BridgeKeyEdit {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyEdit);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeKeyEdit()';
}


}

/// @nodoc
class $BridgeKeyEditCopyWith<$Res>  {
$BridgeKeyEditCopyWith(BridgeKeyEdit _, $Res Function(BridgeKeyEdit) __);
}


/// Adds pattern-matching-related methods to [BridgeKeyEdit].
extension BridgeKeyEditPatterns on BridgeKeyEdit {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( BridgeKeyEdit_Keep value)?  keep,TResult Function( BridgeKeyEdit_Clear value)?  clear,TResult Function( BridgeKeyEdit_Set value)?  set_,required TResult orElse(),}){
final _that = this;
switch (_that) {
case BridgeKeyEdit_Keep() when keep != null:
return keep(_that);case BridgeKeyEdit_Clear() when clear != null:
return clear(_that);case BridgeKeyEdit_Set() when set_ != null:
return set_(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( BridgeKeyEdit_Keep value)  keep,required TResult Function( BridgeKeyEdit_Clear value)  clear,required TResult Function( BridgeKeyEdit_Set value)  set_,}){
final _that = this;
switch (_that) {
case BridgeKeyEdit_Keep():
return keep(_that);case BridgeKeyEdit_Clear():
return clear(_that);case BridgeKeyEdit_Set():
return set_(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( BridgeKeyEdit_Keep value)?  keep,TResult? Function( BridgeKeyEdit_Clear value)?  clear,TResult? Function( BridgeKeyEdit_Set value)?  set_,}){
final _that = this;
switch (_that) {
case BridgeKeyEdit_Keep() when keep != null:
return keep(_that);case BridgeKeyEdit_Clear() when clear != null:
return clear(_that);case BridgeKeyEdit_Set() when set_ != null:
return set_(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  keep,TResult Function()?  clear,TResult Function( String field0)?  set_,required TResult orElse(),}) {final _that = this;
switch (_that) {
case BridgeKeyEdit_Keep() when keep != null:
return keep();case BridgeKeyEdit_Clear() when clear != null:
return clear();case BridgeKeyEdit_Set() when set_ != null:
return set_(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  keep,required TResult Function()  clear,required TResult Function( String field0)  set_,}) {final _that = this;
switch (_that) {
case BridgeKeyEdit_Keep():
return keep();case BridgeKeyEdit_Clear():
return clear();case BridgeKeyEdit_Set():
return set_(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  keep,TResult? Function()?  clear,TResult? Function( String field0)?  set_,}) {final _that = this;
switch (_that) {
case BridgeKeyEdit_Keep() when keep != null:
return keep();case BridgeKeyEdit_Clear() when clear != null:
return clear();case BridgeKeyEdit_Set() when set_ != null:
return set_(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class BridgeKeyEdit_Keep extends BridgeKeyEdit {
  const BridgeKeyEdit_Keep(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyEdit_Keep);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeKeyEdit.keep()';
}


}




/// @nodoc


class BridgeKeyEdit_Clear extends BridgeKeyEdit {
  const BridgeKeyEdit_Clear(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyEdit_Clear);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeKeyEdit.clear()';
}


}




/// @nodoc


class BridgeKeyEdit_Set extends BridgeKeyEdit {
  const BridgeKeyEdit_Set(this.field0): super._();
  

 final  String field0;

/// Create a copy of BridgeKeyEdit
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeKeyEdit_SetCopyWith<BridgeKeyEdit_Set> get copyWith => _$BridgeKeyEdit_SetCopyWithImpl<BridgeKeyEdit_Set>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyEdit_Set&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'BridgeKeyEdit.set_(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $BridgeKeyEdit_SetCopyWith<$Res> implements $BridgeKeyEditCopyWith<$Res> {
  factory $BridgeKeyEdit_SetCopyWith(BridgeKeyEdit_Set value, $Res Function(BridgeKeyEdit_Set) _then) = _$BridgeKeyEdit_SetCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$BridgeKeyEdit_SetCopyWithImpl<$Res>
    implements $BridgeKeyEdit_SetCopyWith<$Res> {
  _$BridgeKeyEdit_SetCopyWithImpl(this._self, this._then);

  final BridgeKeyEdit_Set _self;
  final $Res Function(BridgeKeyEdit_Set) _then;

/// Create a copy of BridgeKeyEdit
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(BridgeKeyEdit_Set(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc
mixin _$BridgeKeyStatus {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyStatus);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeKeyStatus()';
}


}

/// @nodoc
class $BridgeKeyStatusCopyWith<$Res>  {
$BridgeKeyStatusCopyWith(BridgeKeyStatus _, $Res Function(BridgeKeyStatus) __);
}


/// Adds pattern-matching-related methods to [BridgeKeyStatus].
extension BridgeKeyStatusPatterns on BridgeKeyStatus {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( BridgeKeyStatus_Unset value)?  unset,TResult Function( BridgeKeyStatus_InLocalFile value)?  inLocalFile,TResult Function( BridgeKeyStatus_FromEnv value)?  fromEnv,required TResult orElse(),}){
final _that = this;
switch (_that) {
case BridgeKeyStatus_Unset() when unset != null:
return unset(_that);case BridgeKeyStatus_InLocalFile() when inLocalFile != null:
return inLocalFile(_that);case BridgeKeyStatus_FromEnv() when fromEnv != null:
return fromEnv(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( BridgeKeyStatus_Unset value)  unset,required TResult Function( BridgeKeyStatus_InLocalFile value)  inLocalFile,required TResult Function( BridgeKeyStatus_FromEnv value)  fromEnv,}){
final _that = this;
switch (_that) {
case BridgeKeyStatus_Unset():
return unset(_that);case BridgeKeyStatus_InLocalFile():
return inLocalFile(_that);case BridgeKeyStatus_FromEnv():
return fromEnv(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( BridgeKeyStatus_Unset value)?  unset,TResult? Function( BridgeKeyStatus_InLocalFile value)?  inLocalFile,TResult? Function( BridgeKeyStatus_FromEnv value)?  fromEnv,}){
final _that = this;
switch (_that) {
case BridgeKeyStatus_Unset() when unset != null:
return unset(_that);case BridgeKeyStatus_InLocalFile() when inLocalFile != null:
return inLocalFile(_that);case BridgeKeyStatus_FromEnv() when fromEnv != null:
return fromEnv(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  unset,TResult Function( String field0)?  inLocalFile,TResult Function( String field0)?  fromEnv,required TResult orElse(),}) {final _that = this;
switch (_that) {
case BridgeKeyStatus_Unset() when unset != null:
return unset();case BridgeKeyStatus_InLocalFile() when inLocalFile != null:
return inLocalFile(_that.field0);case BridgeKeyStatus_FromEnv() when fromEnv != null:
return fromEnv(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  unset,required TResult Function( String field0)  inLocalFile,required TResult Function( String field0)  fromEnv,}) {final _that = this;
switch (_that) {
case BridgeKeyStatus_Unset():
return unset();case BridgeKeyStatus_InLocalFile():
return inLocalFile(_that.field0);case BridgeKeyStatus_FromEnv():
return fromEnv(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  unset,TResult? Function( String field0)?  inLocalFile,TResult? Function( String field0)?  fromEnv,}) {final _that = this;
switch (_that) {
case BridgeKeyStatus_Unset() when unset != null:
return unset();case BridgeKeyStatus_InLocalFile() when inLocalFile != null:
return inLocalFile(_that.field0);case BridgeKeyStatus_FromEnv() when fromEnv != null:
return fromEnv(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class BridgeKeyStatus_Unset extends BridgeKeyStatus {
  const BridgeKeyStatus_Unset(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyStatus_Unset);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeKeyStatus.unset()';
}


}




/// @nodoc


class BridgeKeyStatus_InLocalFile extends BridgeKeyStatus {
  const BridgeKeyStatus_InLocalFile(this.field0): super._();
  

 final  String field0;

/// Create a copy of BridgeKeyStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeKeyStatus_InLocalFileCopyWith<BridgeKeyStatus_InLocalFile> get copyWith => _$BridgeKeyStatus_InLocalFileCopyWithImpl<BridgeKeyStatus_InLocalFile>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyStatus_InLocalFile&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'BridgeKeyStatus.inLocalFile(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $BridgeKeyStatus_InLocalFileCopyWith<$Res> implements $BridgeKeyStatusCopyWith<$Res> {
  factory $BridgeKeyStatus_InLocalFileCopyWith(BridgeKeyStatus_InLocalFile value, $Res Function(BridgeKeyStatus_InLocalFile) _then) = _$BridgeKeyStatus_InLocalFileCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$BridgeKeyStatus_InLocalFileCopyWithImpl<$Res>
    implements $BridgeKeyStatus_InLocalFileCopyWith<$Res> {
  _$BridgeKeyStatus_InLocalFileCopyWithImpl(this._self, this._then);

  final BridgeKeyStatus_InLocalFile _self;
  final $Res Function(BridgeKeyStatus_InLocalFile) _then;

/// Create a copy of BridgeKeyStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(BridgeKeyStatus_InLocalFile(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class BridgeKeyStatus_FromEnv extends BridgeKeyStatus {
  const BridgeKeyStatus_FromEnv(this.field0): super._();
  

 final  String field0;

/// Create a copy of BridgeKeyStatus
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeKeyStatus_FromEnvCopyWith<BridgeKeyStatus_FromEnv> get copyWith => _$BridgeKeyStatus_FromEnvCopyWithImpl<BridgeKeyStatus_FromEnv>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeKeyStatus_FromEnv&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'BridgeKeyStatus.fromEnv(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $BridgeKeyStatus_FromEnvCopyWith<$Res> implements $BridgeKeyStatusCopyWith<$Res> {
  factory $BridgeKeyStatus_FromEnvCopyWith(BridgeKeyStatus_FromEnv value, $Res Function(BridgeKeyStatus_FromEnv) _then) = _$BridgeKeyStatus_FromEnvCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$BridgeKeyStatus_FromEnvCopyWithImpl<$Res>
    implements $BridgeKeyStatus_FromEnvCopyWith<$Res> {
  _$BridgeKeyStatus_FromEnvCopyWithImpl(this._self, this._then);

  final BridgeKeyStatus_FromEnv _self;
  final $Res Function(BridgeKeyStatus_FromEnv) _then;

/// Create a copy of BridgeKeyStatus
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(BridgeKeyStatus_FromEnv(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
