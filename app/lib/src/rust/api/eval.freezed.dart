// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'eval.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$BridgeEvalEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvalEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeEvalEvent()';
}


}

/// @nodoc
class $BridgeEvalEventCopyWith<$Res>  {
$BridgeEvalEventCopyWith(BridgeEvalEvent _, $Res Function(BridgeEvalEvent) __);
}


/// Adds pattern-matching-related methods to [BridgeEvalEvent].
extension BridgeEvalEventPatterns on BridgeEvalEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( BridgeEvalEvent_Started value)?  started,TResult Function( BridgeEvalEvent_CaseStarted value)?  caseStarted,TResult Function( BridgeEvalEvent_CaseFinished value)?  caseFinished,TResult Function( BridgeEvalEvent_Finished value)?  finished,TResult Function( BridgeEvalEvent_Failed value)?  failed,required TResult orElse(),}){
final _that = this;
switch (_that) {
case BridgeEvalEvent_Started() when started != null:
return started(_that);case BridgeEvalEvent_CaseStarted() when caseStarted != null:
return caseStarted(_that);case BridgeEvalEvent_CaseFinished() when caseFinished != null:
return caseFinished(_that);case BridgeEvalEvent_Finished() when finished != null:
return finished(_that);case BridgeEvalEvent_Failed() when failed != null:
return failed(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( BridgeEvalEvent_Started value)  started,required TResult Function( BridgeEvalEvent_CaseStarted value)  caseStarted,required TResult Function( BridgeEvalEvent_CaseFinished value)  caseFinished,required TResult Function( BridgeEvalEvent_Finished value)  finished,required TResult Function( BridgeEvalEvent_Failed value)  failed,}){
final _that = this;
switch (_that) {
case BridgeEvalEvent_Started():
return started(_that);case BridgeEvalEvent_CaseStarted():
return caseStarted(_that);case BridgeEvalEvent_CaseFinished():
return caseFinished(_that);case BridgeEvalEvent_Finished():
return finished(_that);case BridgeEvalEvent_Failed():
return failed(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( BridgeEvalEvent_Started value)?  started,TResult? Function( BridgeEvalEvent_CaseStarted value)?  caseStarted,TResult? Function( BridgeEvalEvent_CaseFinished value)?  caseFinished,TResult? Function( BridgeEvalEvent_Finished value)?  finished,TResult? Function( BridgeEvalEvent_Failed value)?  failed,}){
final _that = this;
switch (_that) {
case BridgeEvalEvent_Started() when started != null:
return started(_that);case BridgeEvalEvent_CaseStarted() when caseStarted != null:
return caseStarted(_that);case BridgeEvalEvent_CaseFinished() when caseFinished != null:
return caseFinished(_that);case BridgeEvalEvent_Finished() when finished != null:
return finished(_that);case BridgeEvalEvent_Failed() when failed != null:
return failed(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( int total)?  started,TResult Function( int index,  int total,  String id)?  caseStarted,TResult Function( int index,  String id,  bool passed)?  caseFinished,TResult Function( BridgeEvalSummary summary)?  finished,TResult Function( String message)?  failed,required TResult orElse(),}) {final _that = this;
switch (_that) {
case BridgeEvalEvent_Started() when started != null:
return started(_that.total);case BridgeEvalEvent_CaseStarted() when caseStarted != null:
return caseStarted(_that.index,_that.total,_that.id);case BridgeEvalEvent_CaseFinished() when caseFinished != null:
return caseFinished(_that.index,_that.id,_that.passed);case BridgeEvalEvent_Finished() when finished != null:
return finished(_that.summary);case BridgeEvalEvent_Failed() when failed != null:
return failed(_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( int total)  started,required TResult Function( int index,  int total,  String id)  caseStarted,required TResult Function( int index,  String id,  bool passed)  caseFinished,required TResult Function( BridgeEvalSummary summary)  finished,required TResult Function( String message)  failed,}) {final _that = this;
switch (_that) {
case BridgeEvalEvent_Started():
return started(_that.total);case BridgeEvalEvent_CaseStarted():
return caseStarted(_that.index,_that.total,_that.id);case BridgeEvalEvent_CaseFinished():
return caseFinished(_that.index,_that.id,_that.passed);case BridgeEvalEvent_Finished():
return finished(_that.summary);case BridgeEvalEvent_Failed():
return failed(_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( int total)?  started,TResult? Function( int index,  int total,  String id)?  caseStarted,TResult? Function( int index,  String id,  bool passed)?  caseFinished,TResult? Function( BridgeEvalSummary summary)?  finished,TResult? Function( String message)?  failed,}) {final _that = this;
switch (_that) {
case BridgeEvalEvent_Started() when started != null:
return started(_that.total);case BridgeEvalEvent_CaseStarted() when caseStarted != null:
return caseStarted(_that.index,_that.total,_that.id);case BridgeEvalEvent_CaseFinished() when caseFinished != null:
return caseFinished(_that.index,_that.id,_that.passed);case BridgeEvalEvent_Finished() when finished != null:
return finished(_that.summary);case BridgeEvalEvent_Failed() when failed != null:
return failed(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class BridgeEvalEvent_Started extends BridgeEvalEvent {
  const BridgeEvalEvent_Started({required this.total}): super._();
  

 final  int total;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvalEvent_StartedCopyWith<BridgeEvalEvent_Started> get copyWith => _$BridgeEvalEvent_StartedCopyWithImpl<BridgeEvalEvent_Started>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvalEvent_Started&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,total);

@override
String toString() {
  return 'BridgeEvalEvent.started(total: $total)';
}


}

/// @nodoc
abstract mixin class $BridgeEvalEvent_StartedCopyWith<$Res> implements $BridgeEvalEventCopyWith<$Res> {
  factory $BridgeEvalEvent_StartedCopyWith(BridgeEvalEvent_Started value, $Res Function(BridgeEvalEvent_Started) _then) = _$BridgeEvalEvent_StartedCopyWithImpl;
@useResult
$Res call({
 int total
});




}
/// @nodoc
class _$BridgeEvalEvent_StartedCopyWithImpl<$Res>
    implements $BridgeEvalEvent_StartedCopyWith<$Res> {
  _$BridgeEvalEvent_StartedCopyWithImpl(this._self, this._then);

  final BridgeEvalEvent_Started _self;
  final $Res Function(BridgeEvalEvent_Started) _then;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? total = null,}) {
  return _then(BridgeEvalEvent_Started(
total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

/// @nodoc


class BridgeEvalEvent_CaseStarted extends BridgeEvalEvent {
  const BridgeEvalEvent_CaseStarted({required this.index, required this.total, required this.id}): super._();
  

 final  int index;
 final  int total;
 final  String id;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvalEvent_CaseStartedCopyWith<BridgeEvalEvent_CaseStarted> get copyWith => _$BridgeEvalEvent_CaseStartedCopyWithImpl<BridgeEvalEvent_CaseStarted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvalEvent_CaseStarted&&(identical(other.index, index) || other.index == index)&&(identical(other.total, total) || other.total == total)&&(identical(other.id, id) || other.id == id));
}


@override
int get hashCode => Object.hash(runtimeType,index,total,id);

@override
String toString() {
  return 'BridgeEvalEvent.caseStarted(index: $index, total: $total, id: $id)';
}


}

/// @nodoc
abstract mixin class $BridgeEvalEvent_CaseStartedCopyWith<$Res> implements $BridgeEvalEventCopyWith<$Res> {
  factory $BridgeEvalEvent_CaseStartedCopyWith(BridgeEvalEvent_CaseStarted value, $Res Function(BridgeEvalEvent_CaseStarted) _then) = _$BridgeEvalEvent_CaseStartedCopyWithImpl;
@useResult
$Res call({
 int index, int total, String id
});




}
/// @nodoc
class _$BridgeEvalEvent_CaseStartedCopyWithImpl<$Res>
    implements $BridgeEvalEvent_CaseStartedCopyWith<$Res> {
  _$BridgeEvalEvent_CaseStartedCopyWithImpl(this._self, this._then);

  final BridgeEvalEvent_CaseStarted _self;
  final $Res Function(BridgeEvalEvent_CaseStarted) _then;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? index = null,Object? total = null,Object? id = null,}) {
  return _then(BridgeEvalEvent_CaseStarted(
index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class BridgeEvalEvent_CaseFinished extends BridgeEvalEvent {
  const BridgeEvalEvent_CaseFinished({required this.index, required this.id, required this.passed}): super._();
  

 final  int index;
 final  String id;
 final  bool passed;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvalEvent_CaseFinishedCopyWith<BridgeEvalEvent_CaseFinished> get copyWith => _$BridgeEvalEvent_CaseFinishedCopyWithImpl<BridgeEvalEvent_CaseFinished>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvalEvent_CaseFinished&&(identical(other.index, index) || other.index == index)&&(identical(other.id, id) || other.id == id)&&(identical(other.passed, passed) || other.passed == passed));
}


@override
int get hashCode => Object.hash(runtimeType,index,id,passed);

@override
String toString() {
  return 'BridgeEvalEvent.caseFinished(index: $index, id: $id, passed: $passed)';
}


}

/// @nodoc
abstract mixin class $BridgeEvalEvent_CaseFinishedCopyWith<$Res> implements $BridgeEvalEventCopyWith<$Res> {
  factory $BridgeEvalEvent_CaseFinishedCopyWith(BridgeEvalEvent_CaseFinished value, $Res Function(BridgeEvalEvent_CaseFinished) _then) = _$BridgeEvalEvent_CaseFinishedCopyWithImpl;
@useResult
$Res call({
 int index, String id, bool passed
});




}
/// @nodoc
class _$BridgeEvalEvent_CaseFinishedCopyWithImpl<$Res>
    implements $BridgeEvalEvent_CaseFinishedCopyWith<$Res> {
  _$BridgeEvalEvent_CaseFinishedCopyWithImpl(this._self, this._then);

  final BridgeEvalEvent_CaseFinished _self;
  final $Res Function(BridgeEvalEvent_CaseFinished) _then;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? index = null,Object? id = null,Object? passed = null,}) {
  return _then(BridgeEvalEvent_CaseFinished(
index: null == index ? _self.index : index // ignore: cast_nullable_to_non_nullable
as int,id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,passed: null == passed ? _self.passed : passed // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class BridgeEvalEvent_Finished extends BridgeEvalEvent {
  const BridgeEvalEvent_Finished({required this.summary}): super._();
  

 final  BridgeEvalSummary summary;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvalEvent_FinishedCopyWith<BridgeEvalEvent_Finished> get copyWith => _$BridgeEvalEvent_FinishedCopyWithImpl<BridgeEvalEvent_Finished>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvalEvent_Finished&&(identical(other.summary, summary) || other.summary == summary));
}


@override
int get hashCode => Object.hash(runtimeType,summary);

@override
String toString() {
  return 'BridgeEvalEvent.finished(summary: $summary)';
}


}

/// @nodoc
abstract mixin class $BridgeEvalEvent_FinishedCopyWith<$Res> implements $BridgeEvalEventCopyWith<$Res> {
  factory $BridgeEvalEvent_FinishedCopyWith(BridgeEvalEvent_Finished value, $Res Function(BridgeEvalEvent_Finished) _then) = _$BridgeEvalEvent_FinishedCopyWithImpl;
@useResult
$Res call({
 BridgeEvalSummary summary
});




}
/// @nodoc
class _$BridgeEvalEvent_FinishedCopyWithImpl<$Res>
    implements $BridgeEvalEvent_FinishedCopyWith<$Res> {
  _$BridgeEvalEvent_FinishedCopyWithImpl(this._self, this._then);

  final BridgeEvalEvent_Finished _self;
  final $Res Function(BridgeEvalEvent_Finished) _then;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? summary = null,}) {
  return _then(BridgeEvalEvent_Finished(
summary: null == summary ? _self.summary : summary // ignore: cast_nullable_to_non_nullable
as BridgeEvalSummary,
  ));
}


}

/// @nodoc


class BridgeEvalEvent_Failed extends BridgeEvalEvent {
  const BridgeEvalEvent_Failed({required this.message}): super._();
  

 final  String message;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvalEvent_FailedCopyWith<BridgeEvalEvent_Failed> get copyWith => _$BridgeEvalEvent_FailedCopyWithImpl<BridgeEvalEvent_Failed>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvalEvent_Failed&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'BridgeEvalEvent.failed(message: $message)';
}


}

/// @nodoc
abstract mixin class $BridgeEvalEvent_FailedCopyWith<$Res> implements $BridgeEvalEventCopyWith<$Res> {
  factory $BridgeEvalEvent_FailedCopyWith(BridgeEvalEvent_Failed value, $Res Function(BridgeEvalEvent_Failed) _then) = _$BridgeEvalEvent_FailedCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$BridgeEvalEvent_FailedCopyWithImpl<$Res>
    implements $BridgeEvalEvent_FailedCopyWith<$Res> {
  _$BridgeEvalEvent_FailedCopyWithImpl(this._self, this._then);

  final BridgeEvalEvent_Failed _self;
  final $Res Function(BridgeEvalEvent_Failed) _then;

/// Create a copy of BridgeEvalEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(BridgeEvalEvent_Failed(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
