import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' hide log;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:math_tutor_whiteboard/types/features.dart';
// ignore: depend_on_referenced_packages
import 'package:vector_math/vector_math_64.dart' show Quad;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:math_tutor_whiteboard/states/chat_message_state.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'change_notifier_builder.dart';
import 'types/types.dart';
import 'whiteboard_controller.dart';
import 'whiteboard_controller_view.dart';

class MathTutorWhiteboardImpl extends ConsumerStatefulWidget {
  final WhiteboardController? controller;
  final ui.Image? preloadImage;
  final Stream? inputStream;
  final void Function(dynamic data)? onOutput;
  final WhiteboardUser me;
  final FutureOr<void> Function() onAttemptToClose;
  final VoidCallback onTapRecordButton;
  final void Function(File file)? onLoadNewImage;
  final Duration maxRecordingDuration;
  final Set<WhiteboardFeature> enabledFeatures;
  final String? hostID;
  final BatchDrawingData? preDrawnData;
  const MathTutorWhiteboardImpl({
    this.preDrawnData,
    this.hostID,
    required this.enabledFeatures,
    required this.maxRecordingDuration,
    required this.onLoadNewImage,
    super.key,
    this.controller,
    this.preloadImage,
    this.inputStream,
    this.onOutput,
    required this.me,
    required this.onAttemptToClose,
    required this.onTapRecordButton,
  });

  @override
  ConsumerState<MathTutorWhiteboardImpl> createState() =>
      _MathTutorWhiteboardState();
}

class _MathTutorWhiteboardState extends ConsumerState<MathTutorWhiteboardImpl> {
  Map<String, List<List<DrawingData>>> userDrawingData = {};
  PenType penType = PenType.pen;
  double strokeWidth = 2;
  Color color = Colors.black;
  Map<String, int> userLimitCursor = {};
  Timer? timer;
  final Map<String, Map<int, int>> userDeletedStrokes = {};
  StreamSubscription<BroadcastPaintData>? _inputDrawingStreamSubscription;
  StreamSubscription<ImageChangeEvent>? _inputImageStreamSubscription;
  StreamSubscription<WhiteboardChatMessage>? _inputChatStreamSubscription;
  StreamSubscription<ViewportChangeEvent>? _viewportChangeStreamSubscription;
  StreamSubscription<PermissionChangeEvent>? _authorityChangeStreamSubscription;
  StreamSubscription<LiveEndTimeChangeEvent>? _durationChangeStreamSubscription;
  StreamSubscription<RequestDrawingData>? _requestDrawingDataSubscription;
  final transformationController = TransformationController();
  late final Size boardSize;
  ui.Image? image;
  bool drawable = true;
  late final WhiteboardController controller;
  Map<String, List<List<DrawingData>>> hydratedUserDrawingData = {};

  @override
  void initState() {
    drawable = true;
    userLimitCursor = {widget.me.id: 0};
    userDeletedStrokes.addAll({widget.me.id: {}});
    userDrawingData.addAll({widget.me.id: []});
    controller = widget.controller ??
        WhiteboardController(
            recordDuration: widget.maxRecordingDuration,
            recorder: DefaultRecorder());

    /// 만약 미리 주입된 이미지가 있다면, 그 이미지를 미리 불러옵니다.
    if (widget.preloadImage != null) {
      image = widget.preloadImage;
    }

    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (widget.preDrawnData != null) {
        setState(() {
          userDrawingData = Map<String, List<List<DrawingData>>>.from(
              widget.preDrawnData!.drawingData);
          userLimitCursor =
              Map<String, int>.from(widget.preDrawnData!.limitCursor);
          userDeletedStrokes.clear();
          userDeletedStrokes.addAll(widget.preDrawnData!.deletedStrokes);
        });
        if (userDrawingData[widget.me.id] == null) {
          userDrawingData.addAll({widget.me.id: []});
        }
        if (userLimitCursor[widget.me.id] == null) {
          userLimitCursor.addAll({widget.me.id: 0});
        }

        if (userDeletedStrokes[widget.me.id] == null) {
          userDeletedStrokes.addAll({widget.me.id: {}});
        }
      }
      boardSize = Size(MediaQuery.of(context).size.width,
          MediaQuery.of(context).size.width * (16 / 9));
      // boardSize = MediaQuery.of(context).size;
      if (widget.enabledFeatures.contains(WhiteboardFeature.chat)) {
        ref.read(chatMessageStateProvider.notifier).addMessage(
            WhiteboardChatMessage(
                nickname: '시스템',
                message: '채팅방에 입장하셨습니다.',
                sentAt: DateTime.now()));
      }
    });
    if (widget.inputStream != null) {
      widget.inputStream?.listen((event) {
        log('Whiteboard Received Event: $event');
      });

      /// 여기서는 서버의 데이터를 받습니다.
      _inputDrawingStreamSubscription = widget.inputStream
          ?.where((event) => event is BroadcastPaintData)
          .map((event) => event as BroadcastPaintData)
          .listen((_inputDrawingStreamListener));

      _inputImageStreamSubscription = widget.inputStream
          ?.where((event) => event is ImageChangeEvent)
          .map((event) => event as ImageChangeEvent)
          .listen(_inputImageStreamListener);

      _inputChatStreamSubscription = widget.inputStream
          ?.where((event) => event is WhiteboardChatMessage)
          .map((event) => event as WhiteboardChatMessage)
          .listen((event) {
        ref.read(chatMessageStateProvider.notifier).addMessage(event);
      });

      _viewportChangeStreamSubscription = widget.inputStream
          ?.where((event) => event is ViewportChangeEvent)
          .map((event) => event as ViewportChangeEvent)
          .listen((event) {
        transformationController.value = event.adjustedMatrix(boardSize);
      });
      _authorityChangeStreamSubscription = widget.inputStream
          ?.where((event) => event is PermissionChangeEvent)
          .map((event) => event as PermissionChangeEvent)
          .listen((event) {
        if (event.drawing != null && widget.me.id == event.userID) {
          setState(() {
            drawable = event.drawing!;
          });
        }
        if (event.microphone != null && widget.me.id == event.userID) {
          controller.adjustPermissionOfUser(
              userID: event.userID!,
              permissionEvent:
                  PermissionChangeEvent(microphone: event.microphone!));
        }
        if (event.drawing != null) {
          controller.adjustPermissionOfUser(
              userID: event.userID!,
              permissionEvent: PermissionChangeEvent(drawing: event.drawing!));
        }
      });
      _durationChangeStreamSubscription = widget.inputStream
          ?.where((event) => event is LiveEndTimeChangeEvent)
          .map((event) => event as LiveEndTimeChangeEvent)
          .listen((event) {
        controller.setLiveTime(
          liveEndAt: event.endAt,
          liveEndExtraDuration: event.duration,
        );
        controller.startUpdatingLiveTime();
      });

      _requestDrawingDataSubscription = widget.inputStream
          ?.where((event) => event is RequestDrawingData)
          .map((event) => event as RequestDrawingData)
          .listen((event) {
        widget.onOutput?.call(
          BatchDrawingData(
            drawingData: userDrawingData,
            limitCursor: userLimitCursor,
            deletedStrokes: userDeletedStrokes,
            userID: event.participantID,
          ),
        );
      });
    }
    super.initState();
  }

  void _inputDrawingStreamListener(BroadcastPaintData event) {
    /// Command가 clear면 모든 데이터를 지웁니다.
    if (event.command == BroadcastCommand.clear) {
      _onReceiveClear(event.userID);
    } else {
      if (userLimitCursor[event.userID] == null) {
        userLimitCursor[event.userID] = 0;
      }

      if (userDeletedStrokes[event.userID] == null) {
        userDeletedStrokes[event.userID] = {};
      }

      if (userDrawingData[event.userID] == null) {
        userDrawingData[event.userID] = [[]];
      }

      /// 중간에 들어온 경우에는 현재의 limitCursor와 서버에서 내려준 limitCursor가 차이가 납니다.
      /// 정합성을 위해서 부족한 limit Cursor 만큼 빈 스트로크를 추가합니다.
      if (userLimitCursor[event.userID] == 0 && event.limitCursor > 1) {
        userDrawingData[event.userID]!.addAll(List.generate(
            event.limitCursor - userLimitCursor[event.userID]! - 1,
            (index) => []));
        userLimitCursor[event.userID] = event.limitCursor - 1;
      }

      /// 선 지우기 인덱스가 null이 아닌 경우에는
      /// 선을 지우는 동작을 합니다.
      /// 이 경우에는 drawingData가 null입니다.
      if (event.removeStrokeIndex != null) {
        if (userDeletedStrokes[event.userID] == null) {
          userDeletedStrokes[event.userID] = {};
        }
        setState(() {
          userDeletedStrokes[event.userID]![event.limitCursor] =
              event.removeStrokeIndex!;
          userLimitCursor[event.userID] = event.limitCursor;
          userDrawingData[event.userID]!.add([]);
        });
      }

      /// 선 지우기 인덱스가 null인 경우에는
      /// 그리기 동작이거나 Redo Undo 동작입니다.
      /// 그리기 동작이 아닐 경우에는 drawingData가 null입니다.
      /// darwingData가 null이 아닐 경우에는
      /// 호스트의 보드 크기를 참조해 좌표를 조정합니다.
      else {
        final heightCoefficient = boardSize.height / event.boardSize.height;
        final widthCoefficient = boardSize.width / event.boardSize.width;
        setState(() {
          if (event.limitCursor == userLimitCursor[event.userID]) {
            if (event.drawingData != null) {
              userDrawingData[event.userID]!.last.add(
                    event.drawingData!.copyWith(
                      point: event.drawingData!.point.copyWith(
                          x: event.drawingData!.point.x * widthCoefficient,
                          y: event.drawingData!.point.y * heightCoefficient),
                      userID: event.userID,
                    ),
                  );
            }
          } else {
            userLimitCursor[event.userID] = event.limitCursor;
            if (event.drawingData != null) {
              if (userDrawingData[event.userID]!.length <
                  userLimitCursor[event.userID]!) {
                userDrawingData[event.userID]!.add([]);
              }

              /// 간혹 멀티 터치 오류로 limitCursor가 더하기 1을 건너뛰고 들어오는 경우가 있습니다.
              /// 원리 상 . 하나일 수밖에 없기 때문에 생략을 해도 상관이 없어서 정합성을 위해 그냥 빈 스트로크 하나를 추가하고
              /// 그 다음에 들어오는 데이터를 추가합니다.
              if (userLimitCursor[event.userID]! >
                  userDrawingData[event.userID]!.length) {
                userDrawingData[event.userID]!.add([]);
              }
              userDrawingData[event.userID]![
                  userLimitCursor[event.userID]! - 1] = [
                event.drawingData!.copyWith(
                  point: event.drawingData!.point.copyWith(
                      x: event.drawingData!.point.x * widthCoefficient,
                      y: event.drawingData!.point.y * heightCoefficient),
                  userID: event.userID,
                )
              ];
            }
          }
        });
      }
    }
  }

  @override
  void dispose() {
    if (timer != null && timer!.isActive) {
      timer!.cancel();
    }

    _inputDrawingStreamSubscription?.cancel();
    _inputImageStreamSubscription?.cancel();
    _inputChatStreamSubscription?.cancel();
    _viewportChangeStreamSubscription?.cancel();
    _authorityChangeStreamSubscription?.cancel();
    _durationChangeStreamSubscription?.cancel();
    _requestDrawingDataSubscription?.cancel();

    transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: SafeArea(child: Consumer(builder: (context, ref, _) {
        return Column(
          children: [
            ChangeNotifierBuilder(
                notifier: controller,
                builder: (context, controller, _) {
                  if (controller != null) {
                    return WhiteboardControllerView(
                      recordable: widget.enabledFeatures
                          .contains(WhiteboardFeature.recording),
                      controller: controller,
                      onPenSelected: _onPenSelected,
                      onTapEraser: _onTapEraser,
                      onTapUndo: _onTapUndo,
                      me: widget.me,
                      onTapClear: _onTapClear,
                      hostID: widget.hostID,
                      onTapClose: widget.onAttemptToClose,
                      onColorSelected: _onColorSelected,
                      canLoadImage: widget.enabledFeatures
                          .contains(WhiteboardFeature.modifyPhoto),
                      onTapRedo: _onTapRedo,
                      penType: penType,
                      selectedColor: color,
                      isRedoable: userLimitCursor[widget.me.id]! <
                          userDrawingData[widget.me.id]!.length,
                      isUndoable: userLimitCursor[widget.me.id]! > 0,
                      strokeWidth: strokeWidth,
                      onStrokeWidthChanged: _onStrokeWidthChanged,
                      onTapRecord: widget.onTapRecordButton,
                      onTapStrokeEraser: _onTapStrokeEraswer,
                      onLoadImage: _onLoadImage,
                      onSendChatMessage: _onSendChatMessage,
                      drawable: drawable,
                      onDrawingPermissionChanged: _onDrawingPermissionChanged,
                      onMicPermissionChanged: _onMicPermissionChanged,
                      onRequestDrawingPermission: _onRequestDrawingPermission,
                    );
                  } else {
                    return const SizedBox();
                  }
                }),
            Expanded(
              child: _WhiteBoard(
                key: _whiteBoardKey,
                onStartDrawing: _onStartDrawing,
                userDeletedStrokes: userDeletedStrokes,
                transformationController: transformationController,
                onDrawing: _onDrawing,
                onEndDrawing: _onEndDrawing,
                userDrawingData: userDrawingData,
                userLimitCursor: userLimitCursor,
                onViewportChange: _onViewportChange,
                controller: controller,
                backgroundImage: image,
                drawable: drawable,
                isSpannable:
                    widget.enabledFeatures.contains(WhiteboardFeature.span),
                penType: penType,
                onInvalidateCache: _onInvalidateCache,
              ),
            )
          ],
        );
      })),
    );
  }

  void _onStartDrawing() {
    if (penType != PenType.strokeEraser) {
      // If there is redo data, delete all of them and start from there
      if (userLimitCursor[widget.me.id]! <
          userDrawingData[widget.me.id]!.length) {
        userDrawingData[widget.me.id]!.removeRange(
            userLimitCursor[widget.me.id]!,
            userDrawingData[widget.me.id]!.length);
      }
      userDrawingData[widget.me.id]!.add([]);
      userLimitCursor[widget.me.id] = userLimitCursor[widget.me.id]! + 1;
    }
  }

  void _onEndDrawing(event) {
    _draw(event);
  }

  void _onDrawing(event) {
    _draw(event);
  }

  void _onTapClear() {
    setState(() {
      setState(() {
        userDrawingData[widget.me.id]!.clear();
        userDeletedStrokes[widget.me.id]!.clear();
        userLimitCursor[widget.me.id] = 0;
        widget.onOutput?.call(BroadcastPaintData(
            drawingData: null,
            command: BroadcastCommand.clear,
            limitCursor: userLimitCursor[widget.me.id]!,
            userID: widget.me.id,
            boardSize: boardSize));
        log('clear');
      });
    });
  }

  void _onReceiveClear(String userID) {
    setState(() {
      userDrawingData[userID]?.clear();
      userDeletedStrokes[userID]?.clear();
      userLimitCursor[userID] = 0;
    });
  }

  void _onTapUndo() {
    setState(() {
      if (userLimitCursor[widget.me.id]! > 0) {
        userLimitCursor[widget.me.id] = userLimitCursor[widget.me.id]! - 1;
        widget.onOutput?.call(
          BroadcastPaintData(
            drawingData: null,
            command: BroadcastCommand.draw,
            limitCursor: userLimitCursor[widget.me.id]!,
            userID: widget.me.id,
            boardSize: boardSize,
          ),
        );
      }
      log('undo: $userLimitCursor');
    });
  }

  void _onTapEraser() {
    setState(() {
      penType = PenType.penEraser;
      log('eraser selected');
    });
    // 지우개 모드로 전환 시 캐시를 무효화하여 모든 스트로크를 다시 그리도록 함
    _onInvalidateCache();
  }

  void _onTapStrokeEraswer() {
    setState(() {
      penType = PenType.strokeEraser;
      log('stroke eraser selected');
    });
    // 지우개 모드로 전환 시 캐시를 무효화하여 모든 스트로크를 다시 그리도록 함
    _onInvalidateCache();
  }

  // _WhiteBoardState의 캐시를 무효화하기 위한 GlobalKey 사용
  final GlobalKey<_WhiteBoardState> _whiteBoardKey =
      GlobalKey<_WhiteBoardState>();

  void _onInvalidateCache() {
    // _WhiteBoardState의 캐시를 무효화
    _whiteBoardKey.currentState?.invalidateCache();
  }

  void _onPenSelected(PenType type) {
    setState(() {
      penType = type;
      log('pen selected: $type');
    });
  }

  void _onColorSelected(Color color) {
    setState(() {
      this.color = color;
      log('color selected: $color');
    });
  }

  void _onTapRedo() {
    if (userLimitCursor[widget.me.id]! <
        userDrawingData[widget.me.id]!.length) {
      setState(() {
        userLimitCursor[widget.me.id] = userLimitCursor[widget.me.id]! + 1;

        widget.onOutput?.call(BroadcastPaintData(
            drawingData: null,
            command: BroadcastCommand.draw,
            limitCursor: userLimitCursor[widget.me.id]!,
            boardSize: boardSize,
            userID: widget.me.id));
      });
      log('redo: $userLimitCursor');
    }
  }

  void _onStrokeWidthChanged(double strokeWidth) {
    setState(() {
      this.strokeWidth = strokeWidth;
      log('stroke width changed: $strokeWidth');
    });
  }

  void _draw(PointerEvent event) {
    setState(
      () {
        if (penType == PenType.penEraser) {
          // 펜 지우개 모드일 때에는 그냥 투명색으로 똑같이 그려줍니다.
          userDrawingData[widget.me.id]!.last.add(DrawingData(
              point: PointVector(event.localPosition.dx, event.localPosition.dy,
                  event.pressure),
              color: Colors.transparent,
              userID: widget.me.id,
              penType: penType,
              strokeWidth: strokeWidth));
          widget.onOutput?.call(
            BroadcastPaintData(
              drawingData: userDrawingData[widget.me.id]!.last.last,
              command: BroadcastCommand.draw,
              limitCursor: userLimitCursor[widget.me.id]!,
              userID: widget.me.id,
              boardSize: boardSize,
            ),
          );
        } else if (penType == PenType.strokeEraser) {
          /// 선지우기 모드일 때에는 좌표가 해당 선을 스칠 때 선을 통째로 지웁니다.
          /// 지우는 방식은 undo와 redo를 위해서 실제로 지우지 않습니다.
          /// 대신 [deletedStrokes] 라는 [Map]에 key-value로 {지워진 cursor}-{지워진 stroke의 index}를 저장합니다.
          /// 그리고 limitCursor의 정합성을 위해 [limitCursor]를 1 증가시키면서 drawingData에는 빈 스트로크를 채워줍니다.
          /// 그러나 deletedStrokes에 이미 지워진 stroke의 index가 있으면 지우지 않습니다.
          /// 또한 투명색은 펜 지우개 모드가 아니면 선택할 수가 없는 색상이므로
          /// 투명색은 지우개 모드에서 그린 선으로 간주하고 지우지 않습니다.
          for (int i = 0; i < userDrawingData[widget.me.id]!.length; i++) {
            for (int j = 0; j < userDrawingData[widget.me.id]![i].length; j++) {
              if (userDeletedStrokes[widget.me.id]!.containsValue(i) ||
                  userDrawingData[widget.me.id]![i][j].color ==
                      Colors.transparent) {
                continue;
              }
              final distance = sqrt(pow(
                      userDrawingData[widget.me.id]![i][j].point.x -
                          event.localPosition.dx,
                      2) +
                  pow(
                      userDrawingData[widget.me.id]![i][j].point.y -
                          event.localPosition.dy,
                      2));
              if (distance < strokeWidth) {
                widget.onOutput?.call(
                  BroadcastPaintData(
                    drawingData: null,
                    command: BroadcastCommand.removeStroke,
                    limitCursor: userLimitCursor[widget.me.id]!,
                    userID: widget.me.id,
                    boardSize: boardSize,
                    removeStrokeIndex: i,
                  ),
                );

                setState(
                  () {
                    userDrawingData[widget.me.id]!.add([]);
                    userLimitCursor[widget.me.id] =
                        userLimitCursor[widget.me.id]! + 1;
                    userDeletedStrokes[widget.me.id]![
                        userLimitCursor[widget.me.id]!] = i;
                    log('Stroke Erased: $i, $userLimitCursor');
                  },
                );
              }
            }
          }
        } else {
          userDrawingData[widget.me.id]!.last.add(
                DrawingData(
                  point: PointVector(
                      event.localPosition.dx,
                      event.localPosition.dy,
                      penType == PenType.pen ? event.pressure : 0.5),
                  color: color,
                  userID: widget.me.id,
                  penType: penType,
                  strokeWidth: strokeWidth,
                ),
              );
          widget.onOutput?.call(
            BroadcastPaintData(
              drawingData: userDrawingData[widget.me.id]!.last.last,
              boardSize: boardSize,
              command: BroadcastCommand.draw,
              limitCursor: userLimitCursor[widget.me.id]!,
              userID: widget.me.id,
            ),
          );
          log('Drawn: ${BroadcastPaintData(
            drawingData: userDrawingData[widget.me.id]!.last.last,
            boardSize: boardSize,
            command: BroadcastCommand.draw,
            limitCursor: userLimitCursor[widget.me.id]!,
            userID: widget.me.id,
          ).toString()}');
        }
      },
    );
  }

  Future<void> _onLoadImage(ui.Image uiImage) async {
    setState(() {
      image = uiImage;
    });
    final file = File('${(await getTemporaryDirectory()).path}/image.png');
    final imageFile = await file.create();
    final imageByte = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    await imageFile.writeAsBytes(imageByte!.buffer.asUint8List());
    widget.onLoadNewImage?.call(imageFile);
  }

  Future<void> _inputImageStreamListener(ImageChangeEvent event) async {
    await _turnImageUrlToUiImage(event.imageUrl).then((image) => setState(() {
          this.image = image;
        }));
  }

  void _onViewportChange(Matrix4 matrix) {
    widget.onOutput?.call(
      ViewportChangeEvent(
        matrix: matrix,
        boardSize: boardSize,
      ),
    );
  }

  void _onSendChatMessage(String message) {
    widget.onOutput?.call(
      WhiteboardChatMessage(
        message: message,
        nickname: widget.me.nickname,
        sentAt: DateTime.now(),
      ),
    );
    ref.read(chatMessageStateProvider.notifier).addMessage(
          WhiteboardChatMessage(
            message: message,
            nickname: widget.me.nickname,
            sentAt: DateTime.now(),
          ),
        );
  }

  void _onMicPermissionChanged(WhiteboardUser user, bool allow) {
    widget.onOutput
        ?.call(PermissionChangeEvent(microphone: allow, userID: user.id));
    controller.adjustPermissionOfUser(
        userID: user.id,
        permissionEvent:
            PermissionChangeEvent(microphone: allow, userID: user.id));
  }

  void _onDrawingPermissionChanged(WhiteboardUser user, bool allow) {
    widget.onOutput
        ?.call(PermissionChangeEvent(drawing: allow, userID: user.id));
    controller.adjustPermissionOfUser(
        userID: user.id,
        permissionEvent:
            PermissionChangeEvent(drawing: allow, userID: user.id));
  }

  void _onRequestDrawingPermission() {
    widget.onOutput?.call(
      DrawingPermissionRequest(
        nickname: widget.me.nickname,
        userID: widget.me.id,
      ),
    );
  }

  Future<ui.Image?> _turnImageUrlToUiImage(String imageUrl) async {
    if (imageUrl.isNotEmpty) {
      final completer = Completer<ImageInfo>();
      final img = NetworkImage(imageUrl);
      img.resolve(ImageConfiguration.empty).addListener(
        ImageStreamListener((info, _) {
          completer.complete(info);
        }),
      );
      final imageInfo = await completer.future;

      return imageInfo.image;
    } else {
      return null;
    }
  }
}

class _WhiteBoard extends StatefulWidget {
  final void Function() onStartDrawing;
  final void Function(PointerMoveEvent event) onDrawing;
  final void Function(PointerUpEvent event) onEndDrawing;
  final void Function(Matrix4 data) onViewportChange;
  final ui.Image? backgroundImage;
  final Map<String, List<List<DrawingData>>> userDrawingData;
  final Map<String, int> userLimitCursor;
  final Map<String, Map<int, int>> userDeletedStrokes;
  final TransformationController transformationController;
  final bool drawable;
  final bool isSpannable;
  final WhiteboardController controller;
  final PenType penType;
  final VoidCallback? onInvalidateCache;
  const _WhiteBoard(
      {super.key,
      required this.onStartDrawing,
      required this.onDrawing,
      required this.onEndDrawing,
      this.backgroundImage,
      required this.userDrawingData,
      required this.userLimitCursor,
      required this.userDeletedStrokes,
      required this.onViewportChange,
      required this.transformationController,
      required this.drawable,
      required this.isSpannable,
      required this.controller,
      required this.penType,
      this.onInvalidateCache});

  @override
  State<_WhiteBoard> createState() => _WhiteBoardState();
}

class _WhiteBoardState extends State<_WhiteBoard> {
  bool panMode = false;
  late final TransformationController transformationController;
  ui.Image? cachedStrokesImage; // 완성된 스트로크를 이미지로 캐싱
  Map<String, int> lastCachedLimitCursor =
      {}; // 마지막으로 캐시된 limitCursor 추적 (사용자별)
  Map<String, int> pendingCacheLimitCursor =
      {}; // 이미지 변환 중인 limitCursor 추적 (사용자별)
  Size? _whiteboardSize; // 화이트보드의 실제 크기 저장

  @override
  void initState() {
    transformationController = widget.transformationController;
    transformationController.addListener(() {
      if (panMode && widget.controller.pointers.isNotEmpty) {
        log("View Point Changed:");
        widget.onViewportChange(transformationController.value);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [
        SystemUiOverlay.bottom, //This line is used for showing the bottom bar
      ]);
    });
    super.initState();
  }

  @override
  void didUpdateWidget(_WhiteBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 지우개 모드로 전환되면 캐시를 무효화
    if (oldWidget.penType != widget.penType &&
        (widget.penType == PenType.penEraser ||
            widget.penType == PenType.strokeEraser)) {
      _invalidateCache();
    }
  }

  @override
  void dispose() {
    cachedStrokesImage?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [
      SystemUiOverlay.top,
      SystemUiOverlay.bottom,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 화이트보드 크기 계산 및 저장 (실제 렌더링 크기)
    final whiteboardSize = Size(
      MediaQuery.of(context).size.width,
      MediaQuery.of(context).size.height * 4,
    );
    _whiteboardSize = whiteboardSize;

    // Undo/Redo 시 캐시 무효화 체크
    for (final entry in widget.userLimitCursor.entries) {
      final userID = entry.key;
      final currentLimit = entry.value;
      final lastCached = lastCachedLimitCursor[userID] ?? 0;

      // limitCursor가 감소하면 (Undo) 캐시를 무효화
      if (currentLimit < lastCached) {
        // 즉시 캐시를 무효화하여 dispose된 이미지가 paint에 전달되지 않도록 함
        // addPostFrameCallback을 사용하여 build 메서드 완료 후 상태 업데이트
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _invalidateCache();
            });
          }
        });
        break;
      }
    }

    // Clear 시 캐시 무효화 체크
    bool allEmpty = true;
    for (final entry in widget.userDrawingData.entries) {
      if (entry.value.isNotEmpty) {
        allEmpty = false;
        break;
      }
    }
    if (allEmpty && cachedStrokesImage != null) {
      // 즉시 캐시를 무효화하여 dispose된 이미지가 paint에 전달되지 않도록 함
      // addPostFrameCallback을 사용하여 build 메서드 완료 후 상태 업데이트
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _invalidateCache();
          });
        }
      });
    }

    return LayoutBuilder(builder: (context, constraints) {
      return Scaffold(
        floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
        floatingActionButton: widget.drawable && widget.isSpannable
            ? FloatingActionButton.small(
                onPressed: () {
                  setState(() {
                    panMode = !panMode;
                  });
                },
                backgroundColor: Colors.black,
                child: Center(
                    child: Icon(
                  !panMode ? Icons.pan_tool : Icons.edit,
                  color: Colors.white,
                )),
              )
            : null,
        body: InteractiveViewer.builder(
          panEnabled: panMode,
          scaleEnabled: false,
          transformationController: transformationController,
          builder: (BuildContext context, Quad viewport) {
            return Listener(
              onPointerDown: (event) {
                if (widget.drawable) {
                  widget.controller.addPointer(
                    pointer: event.pointer,
                    deviceKind: event.kind,
                  );
                  if (panMode) {
                    return;
                  }
                  if (!widget.controller.isStylusMode) {
                    widget.onStartDrawing();
                  } else {
                    if (event.kind == PointerDeviceKind.invertedStylus ||
                        event.kind == PointerDeviceKind.stylus) {
                      widget.onStartDrawing();
                    }
                  }
                }
              },
              onPointerMove: (event) {
                if (widget.drawable) {
                  if (panMode || widget.controller.isInMultiplePointers) {
                    return;
                  }
                  if (!widget.controller.isStylusMode) {
                    widget.onDrawing(event);
                  } else {
                    if (event.kind == PointerDeviceKind.invertedStylus ||
                        event.kind == PointerDeviceKind.stylus) {
                      widget.onDrawing(event);
                    }
                  }
                }
              },
              onPointerUp: (event) {
                if (widget.drawable) {
                  widget.controller.popPointer(
                      pointer: event.pointer, deviceKind: event.kind);
                  if (panMode) {
                    return;
                  }
                  if (!widget.controller.isStylusMode) {
                    widget.onEndDrawing(event);
                    // 지우개 모드가 아닐 때만 완성된 스트로크를 이미지로 변환
                    // 지우개 모드에서는 모든 스트로크를 실시간으로 그려야 하므로 캐싱하지 않음
                    if (widget.penType != PenType.penEraser &&
                        widget.penType != PenType.strokeEraser) {
                      // 이미지 변환 시작 전에 pendingCacheLimitCursor 설정
                      _prepareCacheForStrokes();
                      _cacheCompletedStrokes();
                    }
                  } else {
                    if (event.kind == PointerDeviceKind.invertedStylus ||
                        event.kind == PointerDeviceKind.stylus) {
                      widget.onEndDrawing(event);
                      // 지우개 모드가 아닐 때만 완성된 스트로크를 이미지로 변환
                      // 지우개 모드에서는 모든 스트로크를 실시간으로 그려야 하므로 캐싱하지 않음
                      if (widget.penType != PenType.penEraser &&
                          widget.penType != PenType.strokeEraser) {
                        // 이미지 변환 시작 전에 pendingCacheLimitCursor 설정
                        _prepareCacheForStrokes();
                        _cacheCompletedStrokes();
                      }
                    }
                  }
                }
              },
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 4,
                width: MediaQuery.of(context).size.width,
                child: Stack(
                  children: [
                    Positioned.fill(child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 실제 렌더링 크기를 사용하여 이미지 생성 시 동일한 크기 사용
                        final actualSize = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        // 첫 렌더링 시 또는 크기가 변경되었을 때만 업데이트
                        if (_whiteboardSize == null ||
                            (_whiteboardSize!.width != actualSize.width ||
                                _whiteboardSize!.height != actualSize.height)) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _whiteboardSize = actualSize;
                              // 크기가 변경되면 캐시 무효화
                              _invalidateCache();
                            }
                          });
                        }
                        return CustomPaint(
                          isComplex: true,
                          foregroundPainter: _WhiteboardPainter(
                              _makeRealDrawingData(),
                              widget.backgroundImage,
                              // 지우개 모드일 때는 캐시된 이미지를 사용하지 않음
                              // 또한 이미지가 유효하지 않으면 null로 전달하여 스트로크를 그리도록 함
                              (widget.penType == PenType.penEraser ||
                                      widget.penType == PenType.strokeEraser)
                                  ? null
                                  : (_isImageValid(cachedStrokesImage)
                                      ? cachedStrokesImage
                                      : null)),
                          size: actualSize,
                          child: Container(
                            color: Colors.transparent,
                          ),
                        );
                      },
                    ))
                  ],
                ),
              ),
            );
          },
        ),
      );
    });
  }

  Map<String, List<List<DrawingData>>> _makeRealDrawingData() {
    /// limitCursor 이전의 스트로크들만 그리되
    /// limitCursor 이전의 key값이 [deletedStrokes]에 존재한다면
    /// [deletedStrokes]의 value값에 해당하는 index를 지워줍니다.
    /// 완성된 스트로크는 이미지로 캐싱되므로, 현재 그려지는 스트로크만 반환합니다.
    /// 단, 지우개 모드일 때는 모든 스트로크를 반환하여 지우개가 작동할 수 있도록 합니다.
    final Map<String, List<List<DrawingData>>> realDrawingData = {};

    /// 유저 별로 그림을 따로 그려줍니다.
    for (final drawingData in widget.userDrawingData.entries) {
      /// 유저 ID를 먼저 가져옵니다.
      final userID = drawingData.key;

      // 지우개 모드일 때는 모든 스트로크를 반환
      if (widget.penType == PenType.penEraser ||
          widget.penType == PenType.strokeEraser) {
        final allStrokes = List<List<DrawingData>>.from(widget
            .userDrawingData[userID]!
            .sublist(0, widget.userLimitCursor[userID]!));

        // 삭제된 스트로크 처리
        for (int i = 0; i < allStrokes.length; i++) {
          for (final deleteStroke
              in widget.userDeletedStrokes[userID]!.entries) {
            if (deleteStroke.key <= widget.userLimitCursor[userID]!) {
              final strokeIndex = deleteStroke.value;
              if (strokeIndex == i) {
                allStrokes[i] = [];
              }
            }
          }
        }
        realDrawingData[userID] = allStrokes;
      } else {
        /// 완성된 스트로크는 이미지로 캐싱되므로,
        /// 마지막으로 캐시된 limitCursor 이후의 스트로크만 반환합니다.
        /// 단, 이미지 변환이 진행 중이거나 이미지가 유효하지 않은 경우에는
        /// 해당 스트로크도 계속 반환하여 화면에 표시되도록 합니다.
        final startIndex = lastCachedLimitCursor[userID] ?? 0;
        final endIndex = widget.userLimitCursor[userID]!;
        final pendingCache = pendingCacheLimitCursor[userID];

        // 캐시된 이미지가 유효한지 확인
        final hasValidCachedImage = _isImageValid(cachedStrokesImage);

        // release 모드에서도 안정적으로 작동하도록:
        // 1. 캐시된 이미지가 없거나 유효하지 않으면 모든 스트로크 반환
        // 2. pendingCache가 있으면 그것과 endIndex 중 더 큰 값 사용
        // 3. 그 외의 경우 endIndex까지의 스트로크 반환
        final effectiveStartIndex =
            (hasValidCachedImage && pendingCache == null)
                ? startIndex
                : 0; // 이미지가 없으면 처음부터 모든 스트로크 반환

        final effectiveEndIndex =
            (pendingCache != null && pendingCache > endIndex)
                ? pendingCache
                : endIndex;

        // effectiveStartIndex가 effectiveEndIndex보다 작으면 스트로크 반환
        if (effectiveStartIndex < effectiveEndIndex) {
          // 배열 범위 체크 추가 (release 모드에서 안전성 향상)
          final dataLength = widget.userDrawingData[userID]!.length;
          final safeEndIndex =
              effectiveEndIndex > dataLength ? dataLength : effectiveEndIndex;

          if (effectiveStartIndex < safeEndIndex) {
            final currentStrokes = widget.userDrawingData[userID]!
                .sublist(effectiveStartIndex, safeEndIndex);

            // 삭제된 스트로크 처리
            for (int i = 0; i < currentStrokes.length; i++) {
              for (final deleteStroke
                  in widget.userDeletedStrokes[userID]!.entries) {
                if (deleteStroke.key <= widget.userLimitCursor[userID]!) {
                  final strokeIndex = deleteStroke.value;
                  if (strokeIndex >= effectiveStartIndex &&
                      strokeIndex < safeEndIndex) {
                    currentStrokes[strokeIndex - effectiveStartIndex] = [];
                  }
                }
              }
            }
            realDrawingData[userID] = currentStrokes;
          } else {
            realDrawingData[userID] = [];
          }
        } else {
          realDrawingData[userID] = [];
        }
      }
    }
    return realDrawingData;
  }

  /// 이미지가 유효한지 확인하는 헬퍼 메서드
  /// dispose된 이미지는 paint할 수 없으므로 확인이 필요합니다.
  bool _isImageValid(ui.Image? image) {
    if (image == null) return false;
    // debugGetOpenHandleStackTraces()가 null이 아니고 비어있지 않으면 이미지가 유효함
    // null이거나 비어있으면 이미 dispose된 이미지
    return image.debugGetOpenHandleStackTraces()?.isNotEmpty ?? false;
  }

  /// 이미지 변환 시작 전에 pendingCacheLimitCursor를 설정합니다.
  /// 이렇게 하면 이미지 변환이 완료되기 전까지 스트로크가 화면에 표시됩니다.
  void _prepareCacheForStrokes() {
    if (!mounted) return;

    bool needsUpdate = false;
    for (final entry in widget.userDrawingData.entries) {
      final userID = entry.key;
      final lastCached = lastCachedLimitCursor[userID] ?? 0;
      final currentLimit = widget.userLimitCursor[userID] ?? 0;

      if (currentLimit > lastCached) {
        final currentPending = pendingCacheLimitCursor[userID];
        // pendingCacheLimitCursor가 설정되지 않았거나 더 작은 값이면 업데이트
        if (currentPending == null || currentPending < currentLimit) {
          pendingCacheLimitCursor[userID] = currentLimit;
          needsUpdate = true;
        }
      }
    }

    // setState를 호출하여 즉시 UI 업데이트
    // release 모드에서도 작동하도록 WidgetsBinding.instance.addPostFrameCallback 사용
    if (needsUpdate && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
      // 즉시 업데이트도 시도
      setState(() {});
    }
  }

  /// 완성된 스트로크를 이미지로 변환하여 캐싱합니다.
  /// 이렇게 하면 많은 스트로크가 있어도 성능 저하를 방지할 수 있습니다.
  Future<void> _cacheCompletedStrokes() async {
    if (!mounted || _whiteboardSize == null) return;

    // CustomPaint의 실제 크기 사용
    final size = _whiteboardSize!;

    // 모든 사용자의 완성된 스트로크 데이터 준비
    final Map<String, List<List<DrawingData>>> completedStrokes = {};
    bool hasNewStrokes = false;

    for (final entry in widget.userDrawingData.entries) {
      final userID = entry.key;
      final lastCached = lastCachedLimitCursor[userID] ?? 0;
      final currentLimit = widget.userLimitCursor[userID] ?? 0;

      if (currentLimit > lastCached) {
        hasNewStrokes = true;
        // 완성된 스트로크만 가져오기 (마지막 캐시 이후 ~ 현재 limitCursor 이전)
        final completed = entry.value.sublist(lastCached, currentLimit);

        // 삭제된 스트로크 처리
        final processedStrokes = <List<DrawingData>>[];
        for (int i = 0; i < completed.length; i++) {
          final strokeIndex = lastCached + i;
          bool isDeleted = false;
          for (final deleteStroke
              in widget.userDeletedStrokes[userID]!.entries) {
            if (deleteStroke.key <= currentLimit &&
                deleteStroke.value == strokeIndex) {
              isDeleted = true;
              break;
            }
          }
          if (!isDeleted) {
            processedStrokes.add(completed[i]);
          } else {
            processedStrokes.add([]);
          }
        }
        completedStrokes[userID] = processedStrokes;
      }
    }

    if (!hasNewStrokes) {
      return;
    }

    // devicePixelRatio를 고려하여 고해상도 이미지 생성
    // release 모드에서도 안정적으로 작동하도록 MediaQuery 사용
    // View.of(context)는 release 모드에서 불안정할 수 있으므로 MediaQuery 사용
    double devicePixelRatio;
    try {
      // MediaQuery는 release 모드에서도 안정적으로 작동함
      devicePixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    } catch (e) {
      // MediaQuery 접근 실패 시 기본값 사용
      devicePixelRatio = 1.0;
    }

    // devicePixelRatio가 유효하지 않으면 기본값 사용
    if (devicePixelRatio <= 0 ||
        devicePixelRatio.isNaN ||
        devicePixelRatio.isInfinite) {
      devicePixelRatio = 1.0;
    }

    final imageWidth = (size.width * devicePixelRatio).toInt();
    final imageHeight = (size.height * devicePixelRatio).toInt();

    // 이미지 크기가 유효한지 먼저 확인
    if (imageWidth <= 0 || imageHeight <= 0) {
      log('Invalid image size: $imageWidth x $imageHeight');
      return;
    }

    // 이미지를 비동기로 생성
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // 고해상도 캔버스로 스케일링
    canvas.scale(devicePixelRatio, devicePixelRatio);

    // 기존 캐시된 이미지가 있으면 먼저 그리기
    // 이미지가 dispose되었는지 확인 후에만 paint
    if (cachedStrokesImage != null && _isImageValid(cachedStrokesImage)) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: cachedStrokesImage!,
        alignment: Alignment.topLeft,
        fit: BoxFit.fill, // 전체 영역을 채우도록 수정
        filterQuality: FilterQuality.none, // 선명도 유지
      );
    }

    // 새로운 완성된 스트로크 그리기
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final drawingData in completedStrokes.values) {
      for (final stroke in drawingData) {
        if (stroke.isEmpty) {
          continue;
        }
        final strokePaint = Paint()
          ..color = stroke.first.penType != PenType.highlighter
              ? stroke.first.color
              : stroke.first.color.withOpacity(0.5)
          ..strokeCap = stroke.first.penType == PenType.pen
              ? StrokeCap.round
              : StrokeCap.square
          ..style = PaintingStyle.fill
          ..strokeWidth = stroke.first.strokeWidth
          ..isAntiAlias = true; // 안티앨리어싱으로 선명도 향상

        if (stroke.first.penType == PenType.penEraser) {
          strokePaint.blendMode = BlendMode.clear;
          strokePaint.style = PaintingStyle.stroke;
        }

        final points = getStroke(
          stroke.map((e) => e.point).toList(),
          options: StrokeOptions(
            size: stroke.first.strokeWidth,
            thinning: stroke.first.penType == PenType.pen ? 0.5 : 0.0,
          ),
        );
        final path = Path();
        if (points.isEmpty) {
          continue;
        } else if (points.length == 1) {
          path.addOval(Rect.fromCircle(
              center: Offset(points[0].dx, points[0].dy),
              radius: stroke.first.strokeWidth));
        } else {
          // 부드러운 곡선을 위해 quadraticBezierTo 사용
          path.moveTo(points[0].dx, points[0].dy);
          if (points.length == 2) {
            // 점이 2개만 있으면 직선으로 연결
            path.lineTo(points[1].dx, points[1].dy);
          } else {
            // 3개 이상의 점이 있으면 곡선으로 연결
            for (int i = 1; i < points.length; i++) {
              if (i == 1) {
                // 첫 번째 점은 직선으로
                path.lineTo(points[i].dx, points[i].dy);
              } else if (i < points.length - 1) {
                // 중간 점들은 이전 점과 현재 점의 중점을 제어점으로 사용하여 부드러운 곡선 생성
                final prev = points[i - 1];
                final curr = points[i];
                final controlX = (prev.dx + curr.dx) / 2;
                final controlY = (prev.dy + curr.dy) / 2;
                path.quadraticBezierTo(
                  controlX,
                  controlY,
                  curr.dx,
                  curr.dy,
                );
              } else {
                // 마지막 점
                path.lineTo(points[i].dx, points[i].dy);
              }
            }
          }
        }
        canvas.drawPath(path, strokePaint);
      }
    }
    canvas.restore();

    // 이미지로 변환 (고해상도)
    final picture = recorder.endRecording();

    // 비동기 이미지 변환 시 위젯이 dispose되었는지 확인
    if (!mounted) {
      picture.dispose();
      return;
    }

    try {
      final image = await picture.toImage(imageWidth, imageHeight);
      picture.dispose();

      // 이미지 변환 후에도 위젯이 여전히 마운트되어 있는지 확인
      if (!mounted) {
        image.dispose();
        return;
      }

      // 기존 이미지 해제 및 새 이미지로 교체
      final oldImage = cachedStrokesImage;
      cachedStrokesImage = image;
      oldImage?.dispose();

      // 마지막 캐시된 limitCursor 업데이트
      // 이미지 변환이 완료되었으므로 pendingCacheLimitCursor도 업데이트
      for (final entry in widget.userDrawingData.entries) {
        final userID = entry.key;
        final currentLimit = widget.userLimitCursor[userID] ?? 0;
        lastCachedLimitCursor[userID] = currentLimit;
        // 이미지 변환이 완료되었으므로 pendingCacheLimitCursor 제거
        pendingCacheLimitCursor.remove(userID);
      }
      // UI 업데이트를 위해 setState 호출
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      // 이미지 변환 실패 시 에러 로깅 및 정리
      picture.dispose();
      log('Error converting strokes to image: $e');
      // 이미지 변환 실패 시에도 pendingCacheLimitCursor 제거하여
      // 스트로크가 계속 표시되도록 함
      for (final entry in widget.userDrawingData.entries) {
        final userID = entry.key;
        pendingCacheLimitCursor.remove(userID);
      }
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// Undo/Redo 시 캐시를 재생성합니다.
  void _invalidateCache() {
    cachedStrokesImage?.dispose();
    cachedStrokesImage = null;
    lastCachedLimitCursor.clear();
    pendingCacheLimitCursor.clear();
  }

  /// 외부에서 캐시를 무효화하기 위한 public 메서드
  void invalidateCache() {
    _invalidateCache();
    if (mounted) {
      setState(() {});
    }
  }
}

class _WhiteboardPainter extends CustomPainter {
  final Map<String, List<List<DrawingData>>> userDrawingData;
  final ui.Image? backgroundImage;
  final ui.Image? cachedStrokesImage;

  _WhiteboardPainter(this.userDrawingData,
      [this.backgroundImage, this.cachedStrokesImage]);

  /// 이미지가 유효한지 확인하는 헬퍼 메서드
  /// dispose된 이미지는 paint할 수 없으므로 확인이 필요합니다.
  bool _isImageValid(ui.Image? image) {
    if (image == null) return false;
    // debugGetOpenHandleStackTraces()가 null이 아니고 비어있지 않으면 이미지가 유효함
    // null이거나 비어있으면 이미 dispose된 이미지
    return image.debugGetOpenHandleStackTraces()?.isNotEmpty ?? false;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 배경 이미지 그리기
    if (backgroundImage != null && _isImageValid(backgroundImage)) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: backgroundImage!,
        alignment: Alignment.topLeft,
        fit: BoxFit.fitWidth,
      );
    }

    // 캐시된 완성된 스트로크 이미지 그리기
    // 이미지가 dispose되었는지 확인 후에만 paint
    if (cachedStrokesImage != null && _isImageValid(cachedStrokesImage)) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: cachedStrokesImage!,
        alignment: Alignment.topLeft,
        fit: BoxFit.fill, // 전체 영역을 채우도록 수정
        filterQuality: FilterQuality.none, // 선명도 유지 (고해상도 이미지이므로)
      );
    }

    // 현재 그려지는 스트로크만 실시간으로 그리기
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final drawingData in userDrawingData.values) {
      for (final stroke in drawingData) {
        if (stroke.isEmpty) {
          continue;
        }
        final paint = Paint()
          ..color = stroke.first.penType != PenType.highlighter
              ? stroke.first.color
              : stroke.first.color.withOpacity(0.5)
          ..strokeCap = stroke.first.penType == PenType.pen
              ? StrokeCap.round
              : StrokeCap.square
          ..style = PaintingStyle.fill
          ..strokeWidth = stroke.first.strokeWidth
          ..isAntiAlias = true; // 안티앨리어싱으로 선명도 향상

        if (stroke.first.penType == PenType.penEraser) {
          paint.blendMode = BlendMode.clear;
          paint.style = PaintingStyle.stroke;
        }

        final points = getStroke(
          stroke.map((e) => e.point).toList(),
          options: StrokeOptions(
            size: stroke.first.strokeWidth,
            thinning: stroke.first.penType == PenType.pen ? 0.5 : 0.0,
          ),
        );
        final path = Path();
        if (points.isEmpty) {
          return;
        } else if (points.length == 1) {
          path.addOval(Rect.fromCircle(
              center: Offset(points[0].dx, points[0].dy),
              radius: stroke.first.strokeWidth));
        } else {
          // 부드러운 곡선을 위해 quadraticBezierTo 사용
          path.moveTo(points[0].dx, points[0].dy);
          if (points.length == 2) {
            // 점이 2개만 있으면 직선으로 연결
            path.lineTo(points[1].dx, points[1].dy);
          } else {
            // 3개 이상의 점이 있으면 곡선으로 연결
            for (int i = 1; i < points.length; i++) {
              if (i == 1) {
                // 첫 번째 점은 직선으로
                path.lineTo(points[i].dx, points[i].dy);
              } else if (i < points.length - 1) {
                // 중간 점들은 이전 점과 현재 점의 중점을 제어점으로 사용하여 부드러운 곡선 생성
                final prev = points[i - 1];
                final curr = points[i];
                final controlX = (prev.dx + curr.dx) / 2;
                final controlY = (prev.dy + curr.dy) / 2;
                path.quadraticBezierTo(
                  controlX,
                  controlY,
                  curr.dx,
                  curr.dy,
                );
              } else {
                // 마지막 점
                path.lineTo(points[i].dx, points[i].dy);
              }
            }
          }
          canvas.drawPath(path, paint);
        }
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WhiteboardPainter oldDelegate) {
    return true;
  }
}
