import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localsend_app/constants.dart';
import 'package:localsend_app/model/dto/info_dto.dart';
import 'package:localsend_app/model/dto/send_request_dto.dart';
import 'package:localsend_app/model/file_status.dart';
import 'package:localsend_app/model/file_type.dart';
import 'package:localsend_app/model/server/receive_state.dart';
import 'package:localsend_app/model/server/receiving_file.dart';
import 'package:localsend_app/model/server/server_state.dart';
import 'package:localsend_app/model/session_status.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/fingerprint_provider.dart';
import 'package:localsend_app/provider/progress_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/alias_generator.dart';
import 'package:localsend_app/util/api_route_builder.dart';
import 'package:localsend_app/util/device_info_helper.dart';
import 'package:localsend_app/util/file_path_helper.dart';
import 'package:localsend_app/util/file_saver.dart';
import 'package:localsend_app/util/platform_check.dart';
import 'package:localsend_app/util/security_helper.dart';
import 'package:localsend_app/util/tray_helper.dart';
import 'package:path_provider/path_provider.dart' as path;
import 'package:routerino/routerino.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

/// This provider manages receiving file requests.
final serverProvider = StateNotifierProvider<ServerNotifier, ServerState?>((ref) {
  final deviceInfo = ref.watch(deviceRawInfoProvider);
  return ServerNotifier(ref, deviceInfo);
});

const _uuid = Uuid();

class ServerNotifier extends StateNotifier<ServerState?> {
  final DeviceInfoResult deviceInfo;
  final Ref _ref;

  ServerNotifier(this._ref, this.deviceInfo) : super(null);

  Future<ServerState?> startServer({required String alias, required int port, required bool https}) async {
    if (state != null) {
      print('Server already running.');
      return null;
    }

    alias = alias.trim();
    if (alias.isEmpty) {
      alias = generateRandomAlias();
    }

    if (port < 0 || port > 65535) {
      port = defaultPort;
    }

    final router = Router();
    _configureRoutes(
      router: router,
      alias: alias,
      port: port,
      https: https,
      fingerprint: _ref.read(fingerprintProvider),
      showToken: _ref.read(settingsProvider.select((s) => s.showToken)),
    );

    print('Starting server...');
    ServerState? newServerState;

    if (https) {
      final securityContextResult = generateSecurityContext();
      newServerState = ServerState(
        httpServer: await serve(router, '0.0.0.0', port,
            securityContext: SecurityContext()
              ..usePrivateKeyBytes(securityContextResult.privateKey.codeUnits)
              ..useCertificateChainBytes(securityContextResult.certificate.codeUnits)),
        alias: alias,
        port: port,
        https: true,
        receiveState: null,
      );
      print('Server started. (Port: ${newServerState.port}, HTTPS only)');
    } else {
      newServerState = ServerState(
        httpServer: await serve(router, '0.0.0.0', port),
        alias: alias,
        port: port,
        https: false,
        receiveState: null,
      );
      print('Server started. (Port: ${newServerState.port}, HTTP only)');
    }

    state = newServerState;
    return newServerState;
  }

  void _configureRoutes({
    required Router router,
    required String alias,
    required int port,
    required bool https,
    required String fingerprint,
    required String showToken,
  }) {
    router.get(ApiRoute.info.path, (Request request) {
      final senderFingerprint = request.url.queryParameters['fingerprint'];
      if (senderFingerprint == fingerprint) {
        // "I talked to myself lol"
        return _response(412, message: 'Self-discovered');
      }

      final dto = InfoDto(
        alias: alias,
        deviceModel: deviceInfo.deviceModel,
        deviceType: deviceInfo.deviceType,
      );

      return _response(200, body: dto.toJson());
    });

    router.post(ApiRoute.sendRequest.path, (Request request) async {
      if (state!.receiveState != null) {
        // block incoming requests when we are already in a session
        return _response(409, message: 'Blocked by another session');
      }

      final payload = await request.readAsString();
      final SendRequestDto dto;
      try {
        dto = SendRequestDto.fromJson(jsonDecode(payload));
      } catch (e) {
        return _response(400, message: 'Request body malformed');
      }

      if (dto.files.isEmpty) {
        // block empty requests (at least one file is required)
        return _response(400, message: 'Request must contain at least one file');
      }

      final settings = _ref.read(settingsProvider);
      String? destinationDir = settings.destination;
      if (destinationDir == null) {
        switch (defaultTargetPlatform) {
          case TargetPlatform.android:
            destinationDir = '/storage/emulated/0/Download';
            break;
          case TargetPlatform.iOS:
            destinationDir = (await path.getApplicationDocumentsDirectory()).path;
            break;
          case TargetPlatform.linux:
          case TargetPlatform.macOS:
          case TargetPlatform.windows:
          case TargetPlatform.fuchsia:
            destinationDir = (await path.getDownloadsDirectory())!.path.replaceAll('\\', '/');
            break;
        }
      }

      print('Destination Directory: $destinationDir');

      final streamController = StreamController<Map<String, String>?>();
      state = state!.copyWith(
        receiveState: ReceiveState(
          status: SessionStatus.waiting,
          sender: dto.info.toDevice(request.ip, port, https),
          files: {
            for (final file in dto.files.values)
              file.id: ReceivingFile(
                file: file,
                status: FileStatus.queue,
                token: null,
                desiredName: null,
                path: null,
                savedToGallery: false,
                errorMessage: null,
              ),
          },
          startTime: null,
          endTime: null,
          destinationDirectory: destinationDir,
          responseHandler: streamController,
        ),
      );

      final quickSave = settings.quickSave && state?.receiveState?.message == null;
      final Map<String, String>? selection;
      if (quickSave) {
        // accept all files
        selection = {
          for (final f in dto.files.values) f.id: f.fileName,
        };
      } else {
        if (checkPlatformHasTray() &&
            (await windowManager.isMinimized() || !(await windowManager.isVisible()) || !(await windowManager.isFocused()))) {
          await showFromTray();
        }

        // ignore: use_build_context_synchronously
        Routerino.context.push(() => const ReceivePage());

        // Delayed response (waiting for user's decision)
        selection = await streamController.stream.first;
      }

      if (state?.receiveState == null) {
        // somehow this state is already disposed
        return _response(500, message: 'Server is in invalid state');
      }

      if (selection != null) {
        if (selection.isEmpty) {
          // nothing selected, send this to sender and close session
          closeSession();
          return _response(200);
        }

        final receiveState = state!.receiveState!;
        state = state!.copyWith(
          receiveState: receiveState.copyWith(
            status: SessionStatus.sending,
            files: Map.fromEntries(
              receiveState.files.values.map((entry) {
                final desiredName = selection![entry.file.id];
                return MapEntry(
                  entry.file.id,
                  ReceivingFile(
                    file: entry.file,
                    status: desiredName != null ? FileStatus.queue : FileStatus.skipped,
                    token: desiredName != null ? _uuid.v4() : null,
                    desiredName: desiredName,
                    path: null,
                    savedToGallery: false,
                    errorMessage: null,
                  ),
                );
              }),
            ),
            responseHandler: null,
          ),
        );

        _ref.read(progressProvider.notifier).reset();

        if (quickSave) {
          // ignore: use_build_context_synchronously
          Routerino.context.pushImmediately(() => const ProgressPage());
        }

        return _response(200, body: {
          for (final file in state!.receiveState!.files.values.where((f) => f.token != null)) file.file.id: file.token,
        });
      } else {
        closeSession();
        return _response(403, message: 'File request declined by recipient');
      }
    });

    router.post(ApiRoute.send.path, (Request request) async {
      final receiveState = state?.receiveState;
      if (receiveState == null) {
        return _response(409, message: 'No session');
      }

      if (request.ip != receiveState.sender.ip) {
        print('Invalid ip address: ${request.ip} (expected: ${receiveState.sender.ip})');
        return _response(403, message: 'Invalid IP address: ${request.ip}');
      }

      if (receiveState.status != SessionStatus.sending) {
        print('Wrong state: ${receiveState.status} (expected: ${SessionStatus.sending})');
        return _response(409, message: 'Recipient is in wrong state');
      }

      final fileId = request.url.queryParameters['fileId'];
      final token = request.url.queryParameters['token'];
      if (fileId == null || token == null) {
        // reject because of missing parameters
        print('Missing parameters');
        return _response(400, message: 'Missing parameters');
      }

      final receivingFile = receiveState.files[fileId];
      if (receivingFile == null || receivingFile.token != token) {
        // reject because there is no file or token does not match
        print('Wrong token: $token (expected: ${receivingFile?.token})');
        return _response(403, message: 'Invalid token');
      }

      // begin of actual file transfer
      state = state?.copyWith(
        receiveState: receiveState.copyWith(
          files: {...receiveState.files}..update(
              fileId,
              (_) => receivingFile.copyWith(
                status: FileStatus.sending,
                token: null, // remove token to reject further uploads of the same file
              ),
            ),
          startTime: receiveState.startTime ?? DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final destinationPath = await _digestFilePath(
        dir: receiveState.destinationDirectory,
        fileName: receivingFile.desiredName!,
      );

      print('Saving ${receivingFile.file.fileName} to $destinationPath');

      try {
        final saveToGallery = checkPlatformWithGallery() &&
            _ref.read(settingsProvider).saveToGallery &&
            (receivingFile.file.fileType == FileType.image || receivingFile.file.fileType == FileType.video);
        await saveFile(
          destinationPath: destinationPath,
          name: receivingFile.desiredName!,
          saveToGallery: saveToGallery,
          stream: request.read(),
          onProgress: (savedBytes) {
            if (receivingFile.file.size != 0) {
              _ref.read(progressProvider.notifier).setProgress(fileId, savedBytes / receivingFile.file.size);
            }
          },
        );
        if (state?.receiveState == null || state!.receiveState!.status != SessionStatus.sending) {
          return _response(500, message: 'Server is in invalid state');
        }
        state = state?.copyWith(
          receiveState: state?.receiveState?.fileFinished(
            fileId: fileId,
            status: FileStatus.finished,
            path: saveToGallery ? null : destinationPath,
            savedToGallery: saveToGallery,
            errorMessage: null,
          ),
        );

        // Track it in history
        await _ref.read(receiveHistoryProvider.notifier).addEntry(
              id: fileId,
              fileName: receivingFile.desiredName!,
              fileType: receivingFile.file.fileType,
              path: saveToGallery ? null : destinationPath,
              savedToGallery: saveToGallery,
              fileSize: receivingFile.file.size,
              senderAlias: receiveState.sender.alias,
              timestamp: DateTime.now().toUtc(),
            );

        print('Saved ${receivingFile.file.fileName}.');
      } catch (e, st) {
        state = state?.copyWith(
          receiveState: state?.receiveState?.fileFinished(
            fileId: fileId,
            status: FileStatus.failed,
            path: null,
            savedToGallery: false,
            errorMessage: e.toString(),
          ),
        );
        print(e);
        print(st);
      }

      final progressNotifier = _ref.read(progressProvider.notifier);
      progressNotifier.setProgress(fileId, 1);

      if (state!.receiveState!.files.values
          .every((f) => f.status == FileStatus.finished || f.status == FileStatus.skipped || f.status == FileStatus.failed)) {
        final hasError = state!.receiveState!.files.values.any((f) => f.status == FileStatus.failed);
        state = state?.copyWith(
          receiveState: state!.receiveState!.copyWith(
            status: hasError ? SessionStatus.finishedWithErrors : SessionStatus.finished,
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        );
        if (_ref.read(settingsProvider).quickSave && state?.receiveState?.message == null) {
          // close the session after return of the response
          Future.delayed(Duration.zero, () {
            closeSession();
            // ignore: use_build_context_synchronously
            Routerino.context.popUntilRoot();
          });
        }
        print('Received all files.');
      }

      return state?.receiveState?.files[fileId]?.status == FileStatus.finished
          ? _response(200)
          : _response(500, message: 'Could not save file');
    });

    router.post(ApiRoute.cancel.path, (Request request) {
      if (state?.receiveState?.sender.ip == request.ip) {
        _cancelBySender();
      }

      return _response(200);
    });

    router.post(ApiRoute.show.path, (Request request) async {
      final senderToken = request.url.queryParameters['token'];
      if (senderToken == showToken && checkPlatformIsDesktop()) {
        showFromTray().catchError((e) {
          // don't wait for it
          print(e);
        });
        return _response(200);
      }

      return _response(403, message: 'Invalid token');
    });
  }

  Future<void> stopServer() async {
    await state?.httpServer.close(force: true);
    state = null;
    print('Server stopped.');
  }

  Future<ServerState?> restartServer({required String alias, required int port, required bool https}) async {
    await stopServer();
    return await startServer(alias: alias, port: port, https: https);
  }

  void acceptFileRequest(Map<String, String> fileNameMap) {
    final controller = state?.receiveState?.responseHandler;
    if (controller == null) {
      return;
    }

    controller.add(fileNameMap);
    controller.close();
  }

  void declineFileRequest() {
    final controller = state?.receiveState?.responseHandler;
    if (controller == null) {
      return;
    }

    controller.add(null);
    controller.close();
  }

  /// Updates the destination directory for the current session.
  void setSessionDestinationDir(String destinationDirectory) {
    state = state?.copyWith(
      receiveState: state?.receiveState?.copyWith(
        destinationDirectory: destinationDirectory.replaceAll('\\', '/'),
      ),
    );
  }

  void _cancelBySender() {
    final currentStatus = state?.receiveState?.status;
    if (currentStatus != null && (currentStatus == SessionStatus.waiting || currentStatus == SessionStatus.sending)) {
      Routerino.context.popUntil(ReceivePage); // pop just in case if use is in [ReceiveOptionsPage]
      state = state?.copyWith(
        receiveState: state?.receiveState?.copyWith(
          status: SessionStatus.canceledBySender,
        ),
      );
    }
  }

  /// In addition to [closeSession], this method also cancels incoming requests.
  void cancelSession() {
    final tempState = state;
    if (tempState == null) {
      // the server is not running
      return;
    }
    closeSession();

    // TODO: cancel incoming requests (https://github.com/dart-lang/shelf/issues/319)
    // restartServer(alias: tempState.alias, port: tempState.port);
  }

  void closeSession() {
    state = state?.copyWith(
      receiveState: null,
    );
  }
}

Response _response(int code, {String? message, Map<String, dynamic>? body}) {
  return Response(
    code,
    body: jsonEncode(message != null ? {'message': message} : (body ?? {})),
    headers: {'content-type': 'application/json'},
  );
}

extension on Request {
  String get ip {
    return (context['shelf.io.connection_info'] as HttpConnectionInfo).remoteAddress.address;
  }
}

/// If there is a file with the same name, then it appends a number to its file name
Future<String> _digestFilePath({required String dir, required String fileName}) async {
  String destinationPath;
  int counter = 1;
  do {
    destinationPath = counter == 1 ? '$dir/$fileName' : '$dir/${fileName.withCount(counter)}';
    counter++;
  } while (await File(destinationPath).exists());
  return destinationPath;
}

extension on ReceiveState {
  ReceiveState fileFinished({
    required String fileId,
    required FileStatus status,
    required String? path,
    required bool savedToGallery,
    required String? errorMessage,
  }) {
    return copyWith(
      files: {...files}..update(
          fileId,
          (file) => file.copyWith(
            status: status,
            path: path,
            savedToGallery: savedToGallery,
            errorMessage: errorMessage,
          ),
        ),
    );
  }
}
