// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'api.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$BridgeCommand {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeCommand()';
}


}

/// @nodoc
class $BridgeCommandCopyWith<$Res>  {
$BridgeCommandCopyWith(BridgeCommand _, $Res Function(BridgeCommand) __);
}


/// Adds pattern-matching-related methods to [BridgeCommand].
extension BridgeCommandPatterns on BridgeCommand {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( BridgeCommand_StartSession value)?  startSession,TResult Function( BridgeCommand_StopSession value)?  stopSession,TResult Function( BridgeCommand_Cancel value)?  cancel,TResult Function( BridgeCommand_ConfirmInsert value)?  confirmInsert,TResult Function( BridgeCommand_Reroll value)?  reroll,TResult Function( BridgeCommand_UpdatePreviewText value)?  updatePreviewText,TResult Function( BridgeCommand_SetStyle value)?  setStyle,required TResult orElse(),}){
final _that = this;
switch (_that) {
case BridgeCommand_StartSession() when startSession != null:
return startSession(_that);case BridgeCommand_StopSession() when stopSession != null:
return stopSession(_that);case BridgeCommand_Cancel() when cancel != null:
return cancel(_that);case BridgeCommand_ConfirmInsert() when confirmInsert != null:
return confirmInsert(_that);case BridgeCommand_Reroll() when reroll != null:
return reroll(_that);case BridgeCommand_UpdatePreviewText() when updatePreviewText != null:
return updatePreviewText(_that);case BridgeCommand_SetStyle() when setStyle != null:
return setStyle(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( BridgeCommand_StartSession value)  startSession,required TResult Function( BridgeCommand_StopSession value)  stopSession,required TResult Function( BridgeCommand_Cancel value)  cancel,required TResult Function( BridgeCommand_ConfirmInsert value)  confirmInsert,required TResult Function( BridgeCommand_Reroll value)  reroll,required TResult Function( BridgeCommand_UpdatePreviewText value)  updatePreviewText,required TResult Function( BridgeCommand_SetStyle value)  setStyle,}){
final _that = this;
switch (_that) {
case BridgeCommand_StartSession():
return startSession(_that);case BridgeCommand_StopSession():
return stopSession(_that);case BridgeCommand_Cancel():
return cancel(_that);case BridgeCommand_ConfirmInsert():
return confirmInsert(_that);case BridgeCommand_Reroll():
return reroll(_that);case BridgeCommand_UpdatePreviewText():
return updatePreviewText(_that);case BridgeCommand_SetStyle():
return setStyle(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( BridgeCommand_StartSession value)?  startSession,TResult? Function( BridgeCommand_StopSession value)?  stopSession,TResult? Function( BridgeCommand_Cancel value)?  cancel,TResult? Function( BridgeCommand_ConfirmInsert value)?  confirmInsert,TResult? Function( BridgeCommand_Reroll value)?  reroll,TResult? Function( BridgeCommand_UpdatePreviewText value)?  updatePreviewText,TResult? Function( BridgeCommand_SetStyle value)?  setStyle,}){
final _that = this;
switch (_that) {
case BridgeCommand_StartSession() when startSession != null:
return startSession(_that);case BridgeCommand_StopSession() when stopSession != null:
return stopSession(_that);case BridgeCommand_Cancel() when cancel != null:
return cancel(_that);case BridgeCommand_ConfirmInsert() when confirmInsert != null:
return confirmInsert(_that);case BridgeCommand_Reroll() when reroll != null:
return reroll(_that);case BridgeCommand_UpdatePreviewText() when updatePreviewText != null:
return updatePreviewText(_that);case BridgeCommand_SetStyle() when setStyle != null:
return setStyle(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  startSession,TResult Function()?  stopSession,TResult Function()?  cancel,TResult Function()?  confirmInsert,TResult Function()?  reroll,TResult Function( String text)?  updatePreviewText,TResult Function( BridgeStyle style)?  setStyle,required TResult orElse(),}) {final _that = this;
switch (_that) {
case BridgeCommand_StartSession() when startSession != null:
return startSession();case BridgeCommand_StopSession() when stopSession != null:
return stopSession();case BridgeCommand_Cancel() when cancel != null:
return cancel();case BridgeCommand_ConfirmInsert() when confirmInsert != null:
return confirmInsert();case BridgeCommand_Reroll() when reroll != null:
return reroll();case BridgeCommand_UpdatePreviewText() when updatePreviewText != null:
return updatePreviewText(_that.text);case BridgeCommand_SetStyle() when setStyle != null:
return setStyle(_that.style);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  startSession,required TResult Function()  stopSession,required TResult Function()  cancel,required TResult Function()  confirmInsert,required TResult Function()  reroll,required TResult Function( String text)  updatePreviewText,required TResult Function( BridgeStyle style)  setStyle,}) {final _that = this;
switch (_that) {
case BridgeCommand_StartSession():
return startSession();case BridgeCommand_StopSession():
return stopSession();case BridgeCommand_Cancel():
return cancel();case BridgeCommand_ConfirmInsert():
return confirmInsert();case BridgeCommand_Reroll():
return reroll();case BridgeCommand_UpdatePreviewText():
return updatePreviewText(_that.text);case BridgeCommand_SetStyle():
return setStyle(_that.style);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  startSession,TResult? Function()?  stopSession,TResult? Function()?  cancel,TResult? Function()?  confirmInsert,TResult? Function()?  reroll,TResult? Function( String text)?  updatePreviewText,TResult? Function( BridgeStyle style)?  setStyle,}) {final _that = this;
switch (_that) {
case BridgeCommand_StartSession() when startSession != null:
return startSession();case BridgeCommand_StopSession() when stopSession != null:
return stopSession();case BridgeCommand_Cancel() when cancel != null:
return cancel();case BridgeCommand_ConfirmInsert() when confirmInsert != null:
return confirmInsert();case BridgeCommand_Reroll() when reroll != null:
return reroll();case BridgeCommand_UpdatePreviewText() when updatePreviewText != null:
return updatePreviewText(_that.text);case BridgeCommand_SetStyle() when setStyle != null:
return setStyle(_that.style);case _:
  return null;

}
}

}

/// @nodoc


class BridgeCommand_StartSession extends BridgeCommand {
  const BridgeCommand_StartSession(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand_StartSession);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeCommand.startSession()';
}


}




/// @nodoc


class BridgeCommand_StopSession extends BridgeCommand {
  const BridgeCommand_StopSession(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand_StopSession);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeCommand.stopSession()';
}


}




/// @nodoc


class BridgeCommand_Cancel extends BridgeCommand {
  const BridgeCommand_Cancel(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand_Cancel);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeCommand.cancel()';
}


}




/// @nodoc


class BridgeCommand_ConfirmInsert extends BridgeCommand {
  const BridgeCommand_ConfirmInsert(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand_ConfirmInsert);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeCommand.confirmInsert()';
}


}




/// @nodoc


class BridgeCommand_Reroll extends BridgeCommand {
  const BridgeCommand_Reroll(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand_Reroll);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeCommand.reroll()';
}


}




/// @nodoc


class BridgeCommand_UpdatePreviewText extends BridgeCommand {
  const BridgeCommand_UpdatePreviewText({required this.text}): super._();
  

 final  String text;

/// Create a copy of BridgeCommand
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeCommand_UpdatePreviewTextCopyWith<BridgeCommand_UpdatePreviewText> get copyWith => _$BridgeCommand_UpdatePreviewTextCopyWithImpl<BridgeCommand_UpdatePreviewText>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand_UpdatePreviewText&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'BridgeCommand.updatePreviewText(text: $text)';
}


}

/// @nodoc
abstract mixin class $BridgeCommand_UpdatePreviewTextCopyWith<$Res> implements $BridgeCommandCopyWith<$Res> {
  factory $BridgeCommand_UpdatePreviewTextCopyWith(BridgeCommand_UpdatePreviewText value, $Res Function(BridgeCommand_UpdatePreviewText) _then) = _$BridgeCommand_UpdatePreviewTextCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$BridgeCommand_UpdatePreviewTextCopyWithImpl<$Res>
    implements $BridgeCommand_UpdatePreviewTextCopyWith<$Res> {
  _$BridgeCommand_UpdatePreviewTextCopyWithImpl(this._self, this._then);

  final BridgeCommand_UpdatePreviewText _self;
  final $Res Function(BridgeCommand_UpdatePreviewText) _then;

/// Create a copy of BridgeCommand
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(BridgeCommand_UpdatePreviewText(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class BridgeCommand_SetStyle extends BridgeCommand {
  const BridgeCommand_SetStyle({required this.style}): super._();
  

 final  BridgeStyle style;

/// Create a copy of BridgeCommand
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeCommand_SetStyleCopyWith<BridgeCommand_SetStyle> get copyWith => _$BridgeCommand_SetStyleCopyWithImpl<BridgeCommand_SetStyle>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeCommand_SetStyle&&(identical(other.style, style) || other.style == style));
}


@override
int get hashCode => Object.hash(runtimeType,style);

@override
String toString() {
  return 'BridgeCommand.setStyle(style: $style)';
}


}

/// @nodoc
abstract mixin class $BridgeCommand_SetStyleCopyWith<$Res> implements $BridgeCommandCopyWith<$Res> {
  factory $BridgeCommand_SetStyleCopyWith(BridgeCommand_SetStyle value, $Res Function(BridgeCommand_SetStyle) _then) = _$BridgeCommand_SetStyleCopyWithImpl;
@useResult
$Res call({
 BridgeStyle style
});




}
/// @nodoc
class _$BridgeCommand_SetStyleCopyWithImpl<$Res>
    implements $BridgeCommand_SetStyleCopyWith<$Res> {
  _$BridgeCommand_SetStyleCopyWithImpl(this._self, this._then);

  final BridgeCommand_SetStyle _self;
  final $Res Function(BridgeCommand_SetStyle) _then;

/// Create a copy of BridgeCommand
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? style = null,}) {
  return _then(BridgeCommand_SetStyle(
style: null == style ? _self.style : style // ignore: cast_nullable_to_non_nullable
as BridgeStyle,
  ));
}


}

/// @nodoc
mixin _$BridgeEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeEvent()';
}


}

/// @nodoc
class $BridgeEventCopyWith<$Res>  {
$BridgeEventCopyWith(BridgeEvent _, $Res Function(BridgeEvent) __);
}


/// Adds pattern-matching-related methods to [BridgeEvent].
extension BridgeEventPatterns on BridgeEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( BridgeEvent_SessionStateChanged value)?  sessionStateChanged,TResult Function( BridgeEvent_LiveTranscriptUpdated value)?  liveTranscriptUpdated,TResult Function( BridgeEvent_ParagraphMarked value)?  paragraphMarked,TResult Function( BridgeEvent_RectifiedTextChunk value)?  rectifiedTextChunk,TResult Function( BridgeEvent_PreviewTextUpdated value)?  previewTextUpdated,TResult Function( BridgeEvent_TextInserted value)?  textInserted,TResult Function( BridgeEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case BridgeEvent_SessionStateChanged() when sessionStateChanged != null:
return sessionStateChanged(_that);case BridgeEvent_LiveTranscriptUpdated() when liveTranscriptUpdated != null:
return liveTranscriptUpdated(_that);case BridgeEvent_ParagraphMarked() when paragraphMarked != null:
return paragraphMarked(_that);case BridgeEvent_RectifiedTextChunk() when rectifiedTextChunk != null:
return rectifiedTextChunk(_that);case BridgeEvent_PreviewTextUpdated() when previewTextUpdated != null:
return previewTextUpdated(_that);case BridgeEvent_TextInserted() when textInserted != null:
return textInserted(_that);case BridgeEvent_Error() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( BridgeEvent_SessionStateChanged value)  sessionStateChanged,required TResult Function( BridgeEvent_LiveTranscriptUpdated value)  liveTranscriptUpdated,required TResult Function( BridgeEvent_ParagraphMarked value)  paragraphMarked,required TResult Function( BridgeEvent_RectifiedTextChunk value)  rectifiedTextChunk,required TResult Function( BridgeEvent_PreviewTextUpdated value)  previewTextUpdated,required TResult Function( BridgeEvent_TextInserted value)  textInserted,required TResult Function( BridgeEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case BridgeEvent_SessionStateChanged():
return sessionStateChanged(_that);case BridgeEvent_LiveTranscriptUpdated():
return liveTranscriptUpdated(_that);case BridgeEvent_ParagraphMarked():
return paragraphMarked(_that);case BridgeEvent_RectifiedTextChunk():
return rectifiedTextChunk(_that);case BridgeEvent_PreviewTextUpdated():
return previewTextUpdated(_that);case BridgeEvent_TextInserted():
return textInserted(_that);case BridgeEvent_Error():
return error(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( BridgeEvent_SessionStateChanged value)?  sessionStateChanged,TResult? Function( BridgeEvent_LiveTranscriptUpdated value)?  liveTranscriptUpdated,TResult? Function( BridgeEvent_ParagraphMarked value)?  paragraphMarked,TResult? Function( BridgeEvent_RectifiedTextChunk value)?  rectifiedTextChunk,TResult? Function( BridgeEvent_PreviewTextUpdated value)?  previewTextUpdated,TResult? Function( BridgeEvent_TextInserted value)?  textInserted,TResult? Function( BridgeEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case BridgeEvent_SessionStateChanged() when sessionStateChanged != null:
return sessionStateChanged(_that);case BridgeEvent_LiveTranscriptUpdated() when liveTranscriptUpdated != null:
return liveTranscriptUpdated(_that);case BridgeEvent_ParagraphMarked() when paragraphMarked != null:
return paragraphMarked(_that);case BridgeEvent_RectifiedTextChunk() when rectifiedTextChunk != null:
return rectifiedTextChunk(_that);case BridgeEvent_PreviewTextUpdated() when previewTextUpdated != null:
return previewTextUpdated(_that);case BridgeEvent_TextInserted() when textInserted != null:
return textInserted(_that);case BridgeEvent_Error() when error != null:
return error(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( BridgeSessionState from,  BridgeSessionState to)?  sessionStateChanged,TResult Function( String text)?  liveTranscriptUpdated,TResult Function()?  paragraphMarked,TResult Function( String delta)?  rectifiedTextChunk,TResult Function( String text)?  previewTextUpdated,TResult Function( String text)?  textInserted,TResult Function( String message)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case BridgeEvent_SessionStateChanged() when sessionStateChanged != null:
return sessionStateChanged(_that.from,_that.to);case BridgeEvent_LiveTranscriptUpdated() when liveTranscriptUpdated != null:
return liveTranscriptUpdated(_that.text);case BridgeEvent_ParagraphMarked() when paragraphMarked != null:
return paragraphMarked();case BridgeEvent_RectifiedTextChunk() when rectifiedTextChunk != null:
return rectifiedTextChunk(_that.delta);case BridgeEvent_PreviewTextUpdated() when previewTextUpdated != null:
return previewTextUpdated(_that.text);case BridgeEvent_TextInserted() when textInserted != null:
return textInserted(_that.text);case BridgeEvent_Error() when error != null:
return error(_that.message);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( BridgeSessionState from,  BridgeSessionState to)  sessionStateChanged,required TResult Function( String text)  liveTranscriptUpdated,required TResult Function()  paragraphMarked,required TResult Function( String delta)  rectifiedTextChunk,required TResult Function( String text)  previewTextUpdated,required TResult Function( String text)  textInserted,required TResult Function( String message)  error,}) {final _that = this;
switch (_that) {
case BridgeEvent_SessionStateChanged():
return sessionStateChanged(_that.from,_that.to);case BridgeEvent_LiveTranscriptUpdated():
return liveTranscriptUpdated(_that.text);case BridgeEvent_ParagraphMarked():
return paragraphMarked();case BridgeEvent_RectifiedTextChunk():
return rectifiedTextChunk(_that.delta);case BridgeEvent_PreviewTextUpdated():
return previewTextUpdated(_that.text);case BridgeEvent_TextInserted():
return textInserted(_that.text);case BridgeEvent_Error():
return error(_that.message);}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( BridgeSessionState from,  BridgeSessionState to)?  sessionStateChanged,TResult? Function( String text)?  liveTranscriptUpdated,TResult? Function()?  paragraphMarked,TResult? Function( String delta)?  rectifiedTextChunk,TResult? Function( String text)?  previewTextUpdated,TResult? Function( String text)?  textInserted,TResult? Function( String message)?  error,}) {final _that = this;
switch (_that) {
case BridgeEvent_SessionStateChanged() when sessionStateChanged != null:
return sessionStateChanged(_that.from,_that.to);case BridgeEvent_LiveTranscriptUpdated() when liveTranscriptUpdated != null:
return liveTranscriptUpdated(_that.text);case BridgeEvent_ParagraphMarked() when paragraphMarked != null:
return paragraphMarked();case BridgeEvent_RectifiedTextChunk() when rectifiedTextChunk != null:
return rectifiedTextChunk(_that.delta);case BridgeEvent_PreviewTextUpdated() when previewTextUpdated != null:
return previewTextUpdated(_that.text);case BridgeEvent_TextInserted() when textInserted != null:
return textInserted(_that.text);case BridgeEvent_Error() when error != null:
return error(_that.message);case _:
  return null;

}
}

}

/// @nodoc


class BridgeEvent_SessionStateChanged extends BridgeEvent {
  const BridgeEvent_SessionStateChanged({required this.from, required this.to}): super._();
  

 final  BridgeSessionState from;
 final  BridgeSessionState to;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvent_SessionStateChangedCopyWith<BridgeEvent_SessionStateChanged> get copyWith => _$BridgeEvent_SessionStateChangedCopyWithImpl<BridgeEvent_SessionStateChanged>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent_SessionStateChanged&&(identical(other.from, from) || other.from == from)&&(identical(other.to, to) || other.to == to));
}


@override
int get hashCode => Object.hash(runtimeType,from,to);

@override
String toString() {
  return 'BridgeEvent.sessionStateChanged(from: $from, to: $to)';
}


}

/// @nodoc
abstract mixin class $BridgeEvent_SessionStateChangedCopyWith<$Res> implements $BridgeEventCopyWith<$Res> {
  factory $BridgeEvent_SessionStateChangedCopyWith(BridgeEvent_SessionStateChanged value, $Res Function(BridgeEvent_SessionStateChanged) _then) = _$BridgeEvent_SessionStateChangedCopyWithImpl;
@useResult
$Res call({
 BridgeSessionState from, BridgeSessionState to
});




}
/// @nodoc
class _$BridgeEvent_SessionStateChangedCopyWithImpl<$Res>
    implements $BridgeEvent_SessionStateChangedCopyWith<$Res> {
  _$BridgeEvent_SessionStateChangedCopyWithImpl(this._self, this._then);

  final BridgeEvent_SessionStateChanged _self;
  final $Res Function(BridgeEvent_SessionStateChanged) _then;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? from = null,Object? to = null,}) {
  return _then(BridgeEvent_SessionStateChanged(
from: null == from ? _self.from : from // ignore: cast_nullable_to_non_nullable
as BridgeSessionState,to: null == to ? _self.to : to // ignore: cast_nullable_to_non_nullable
as BridgeSessionState,
  ));
}


}

/// @nodoc


class BridgeEvent_LiveTranscriptUpdated extends BridgeEvent {
  const BridgeEvent_LiveTranscriptUpdated({required this.text}): super._();
  

 final  String text;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvent_LiveTranscriptUpdatedCopyWith<BridgeEvent_LiveTranscriptUpdated> get copyWith => _$BridgeEvent_LiveTranscriptUpdatedCopyWithImpl<BridgeEvent_LiveTranscriptUpdated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent_LiveTranscriptUpdated&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'BridgeEvent.liveTranscriptUpdated(text: $text)';
}


}

/// @nodoc
abstract mixin class $BridgeEvent_LiveTranscriptUpdatedCopyWith<$Res> implements $BridgeEventCopyWith<$Res> {
  factory $BridgeEvent_LiveTranscriptUpdatedCopyWith(BridgeEvent_LiveTranscriptUpdated value, $Res Function(BridgeEvent_LiveTranscriptUpdated) _then) = _$BridgeEvent_LiveTranscriptUpdatedCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$BridgeEvent_LiveTranscriptUpdatedCopyWithImpl<$Res>
    implements $BridgeEvent_LiveTranscriptUpdatedCopyWith<$Res> {
  _$BridgeEvent_LiveTranscriptUpdatedCopyWithImpl(this._self, this._then);

  final BridgeEvent_LiveTranscriptUpdated _self;
  final $Res Function(BridgeEvent_LiveTranscriptUpdated) _then;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(BridgeEvent_LiveTranscriptUpdated(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class BridgeEvent_ParagraphMarked extends BridgeEvent {
  const BridgeEvent_ParagraphMarked(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent_ParagraphMarked);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BridgeEvent.paragraphMarked()';
}


}




/// @nodoc


class BridgeEvent_RectifiedTextChunk extends BridgeEvent {
  const BridgeEvent_RectifiedTextChunk({required this.delta}): super._();
  

 final  String delta;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvent_RectifiedTextChunkCopyWith<BridgeEvent_RectifiedTextChunk> get copyWith => _$BridgeEvent_RectifiedTextChunkCopyWithImpl<BridgeEvent_RectifiedTextChunk>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent_RectifiedTextChunk&&(identical(other.delta, delta) || other.delta == delta));
}


@override
int get hashCode => Object.hash(runtimeType,delta);

@override
String toString() {
  return 'BridgeEvent.rectifiedTextChunk(delta: $delta)';
}


}

/// @nodoc
abstract mixin class $BridgeEvent_RectifiedTextChunkCopyWith<$Res> implements $BridgeEventCopyWith<$Res> {
  factory $BridgeEvent_RectifiedTextChunkCopyWith(BridgeEvent_RectifiedTextChunk value, $Res Function(BridgeEvent_RectifiedTextChunk) _then) = _$BridgeEvent_RectifiedTextChunkCopyWithImpl;
@useResult
$Res call({
 String delta
});




}
/// @nodoc
class _$BridgeEvent_RectifiedTextChunkCopyWithImpl<$Res>
    implements $BridgeEvent_RectifiedTextChunkCopyWith<$Res> {
  _$BridgeEvent_RectifiedTextChunkCopyWithImpl(this._self, this._then);

  final BridgeEvent_RectifiedTextChunk _self;
  final $Res Function(BridgeEvent_RectifiedTextChunk) _then;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? delta = null,}) {
  return _then(BridgeEvent_RectifiedTextChunk(
delta: null == delta ? _self.delta : delta // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class BridgeEvent_PreviewTextUpdated extends BridgeEvent {
  const BridgeEvent_PreviewTextUpdated({required this.text}): super._();
  

 final  String text;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvent_PreviewTextUpdatedCopyWith<BridgeEvent_PreviewTextUpdated> get copyWith => _$BridgeEvent_PreviewTextUpdatedCopyWithImpl<BridgeEvent_PreviewTextUpdated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent_PreviewTextUpdated&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'BridgeEvent.previewTextUpdated(text: $text)';
}


}

/// @nodoc
abstract mixin class $BridgeEvent_PreviewTextUpdatedCopyWith<$Res> implements $BridgeEventCopyWith<$Res> {
  factory $BridgeEvent_PreviewTextUpdatedCopyWith(BridgeEvent_PreviewTextUpdated value, $Res Function(BridgeEvent_PreviewTextUpdated) _then) = _$BridgeEvent_PreviewTextUpdatedCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$BridgeEvent_PreviewTextUpdatedCopyWithImpl<$Res>
    implements $BridgeEvent_PreviewTextUpdatedCopyWith<$Res> {
  _$BridgeEvent_PreviewTextUpdatedCopyWithImpl(this._self, this._then);

  final BridgeEvent_PreviewTextUpdated _self;
  final $Res Function(BridgeEvent_PreviewTextUpdated) _then;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(BridgeEvent_PreviewTextUpdated(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class BridgeEvent_TextInserted extends BridgeEvent {
  const BridgeEvent_TextInserted({required this.text}): super._();
  

 final  String text;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvent_TextInsertedCopyWith<BridgeEvent_TextInserted> get copyWith => _$BridgeEvent_TextInsertedCopyWithImpl<BridgeEvent_TextInserted>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent_TextInserted&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'BridgeEvent.textInserted(text: $text)';
}


}

/// @nodoc
abstract mixin class $BridgeEvent_TextInsertedCopyWith<$Res> implements $BridgeEventCopyWith<$Res> {
  factory $BridgeEvent_TextInsertedCopyWith(BridgeEvent_TextInserted value, $Res Function(BridgeEvent_TextInserted) _then) = _$BridgeEvent_TextInsertedCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$BridgeEvent_TextInsertedCopyWithImpl<$Res>
    implements $BridgeEvent_TextInsertedCopyWith<$Res> {
  _$BridgeEvent_TextInsertedCopyWithImpl(this._self, this._then);

  final BridgeEvent_TextInserted _self;
  final $Res Function(BridgeEvent_TextInserted) _then;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(BridgeEvent_TextInserted(
text: null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class BridgeEvent_Error extends BridgeEvent {
  const BridgeEvent_Error({required this.message}): super._();
  

 final  String message;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BridgeEvent_ErrorCopyWith<BridgeEvent_Error> get copyWith => _$BridgeEvent_ErrorCopyWithImpl<BridgeEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BridgeEvent_Error&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,message);

@override
String toString() {
  return 'BridgeEvent.error(message: $message)';
}


}

/// @nodoc
abstract mixin class $BridgeEvent_ErrorCopyWith<$Res> implements $BridgeEventCopyWith<$Res> {
  factory $BridgeEvent_ErrorCopyWith(BridgeEvent_Error value, $Res Function(BridgeEvent_Error) _then) = _$BridgeEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String message
});




}
/// @nodoc
class _$BridgeEvent_ErrorCopyWithImpl<$Res>
    implements $BridgeEvent_ErrorCopyWith<$Res> {
  _$BridgeEvent_ErrorCopyWithImpl(this._self, this._then);

  final BridgeEvent_Error _self;
  final $Res Function(BridgeEvent_Error) _then;

/// Create a copy of BridgeEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? message = null,}) {
  return _then(BridgeEvent_Error(
message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
