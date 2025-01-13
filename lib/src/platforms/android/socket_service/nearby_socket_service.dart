import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:nearby_service/nearby_service.dart';
import 'package:nearby_service/src/utils/file_socket.dart';
import 'package:nearby_service/src/utils/listenable.dart';
import 'package:nearby_service/src/utils/logger.dart';
import 'package:nearby_service/src/utils/random.dart';
import 'package:nearby_service/src/utils/stream_mapper.dart';

import 'package:cryptography/cryptography.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

part 'ping_manager.dart';

part 'network.dart';

part 'file_sockets_manager.dart';

///
/// A service for creating a communication channel on the Android platform.
///
class NearbySocketService {
  NearbySocketService(this._service);

  final NearbyAndroidService _service;
  final _pingManager = NearbySocketPingManager();
  final _network = NearbyServiceNetwork();
  late final _fileSocketsManager = FileSocketsManager(
    _network,
    _service,
    _pingManager,
  );

  late final state = NearbyServiceListenable<CommunicationChannelState>(
    initialValue: CommunicationChannelState.notConnected,
  );

  NearbyAndroidCommunicationChannelData _androidData =
      const NearbyAndroidCommunicationChannelData();

  String? _connectedDeviceId;
  WebSocket? _socket;
  HttpServer? _server;
  StreamSubscription? _messagesSubscription;

  CommunicationChannelState get communicationChannelStateValue => state.value;

  ValueListenable<CommunicationChannelState> get communicationChannelState =>
      state.notifier;

  ///
  /// Start a socket with the user's role defined.
  /// If he is the owner of the group, he becomes a server.
  /// Otherwise, he becomes a client.
  ///
  /// * The server starts up and waits for a request from the
  /// client to establish a connection.
  /// * The client pings the server until he receives a pong.
  /// When he does, he tries to connect to the server.
  ///
  Future<bool> startSocket({
    required NearbyCommunicationChannelData data,
  }) async {
    state.add(CommunicationChannelState.loading);

    _androidData = data.androidData;
    _connectedDeviceId = data.connectedDeviceId;

    _fileSocketsManager
      ..setListener(data.filesListener)
      ..setConnectionData(data.androidData);

    final info = await _service.getConnectionInfo();

    if (info != null && info.groupFormed) {
      if (info.isGroupOwner) {
        await _startServerSubscription(
          socketListener: data.messagesListener,
          info: info,
        );
        return true;
      } else {
        await _tryConnectClient(
          socketListener: data.messagesListener,
          info: info,
        );
        return true;
      }
    } else {
      Future.delayed(data.androidData.clientReconnectInterval, () {
        startSocket(data: data);
      });
      return false;
    }
  }

  ///
  /// Adds [OutgoingNearbyMessage]'s binary representation to the [_socket].
  ///
  // Future<bool> send(OutgoingNearbyMessage message) async {
  //   if (message.isValid) {
  //     if (_socket != null && message.receiver.id == _connectedDeviceId) {
  //       final sender = await _service.getCurrentDeviceInfo();
  //       if (sender != null) {
  //         final jsonString = jsonEncode({
  //           'content': message.content.toJson(),
  //           'sender': sender.toJson(),
  //         });

  //         final binaryData = Uint8List.fromList(utf8.encode(jsonString));
  //         Logger.debug('Sending binary data: $binaryData');
  //         _socket!.add(binaryData);
  //         _handleFilesMessage(message);
  //       }
  //       return true;
  //     }
  //     return false;
  //   } else {
  //     throw NearbyServiceException.invalidMessage(message.content);
  //   }
  // }
  /// for encryption, we can utilize the following

  Future<bool> send(OutgoingNearbyMessage message, [String? recieverId]) async {
  if (message.isValid) {
    // log the message
    Logger.debug('Sending message: $message');
    if (_socket != null && message.receiver.id == _connectedDeviceId) {
      final sender = await _service.getCurrentDeviceInfo();
      if (sender != null) {
        final jsonString = jsonEncode({
          'content': message.content.toJson(),
          'sender': sender.toJson(),
        });

        // Encrypt the JSON string
        // final algorithm = AesGcm.with256bits();
        // final secretKeyBytes = recieverId != null ? utf8.encode(recieverId) : utf8.encode('iBayanihan' * 4);
        // final secretKey = SecretKey(secretKeyBytes);
        // final nonce = algorithm.newNonce();
        // final secretBox = await algorithm.encrypt(
        //   utf8.encode(jsonString),
        //   secretKey: secretKey,
        //   nonce: nonce,
        // );

        final key = Key.fromUtf8('iBayanihan' * 4);

        final iv = IV.fromUtf8('iBayanihan' * 4);
        final encrypter = Encrypter(AES(key));

        final encrypted = encrypter.encrypt(jsonString, iv: iv);

        Logger.debug('Sending encrypted binary data: $encrypted');
        _socket!.add(encrypted);
        _handleFilesMessage(message);
      }
      return true;
    }
    return false;
  } else {
    throw NearbyServiceException.invalidMessage(message.content);
  }
}


  ///
  /// Turns off [_messagesSubscription] and [_socket].
  ///
  Future<bool> cancel() async {
    try {
      await _messagesSubscription?.cancel();
      await _fileSocketsManager.closeAll();

      _messagesSubscription = null;
      _socket?.close();
      _socket = null;
      _server?.close(force: true);
      _server = null;
      _connectedDeviceId = null;

      state.add(CommunicationChannelState.notConnected);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _tryConnectClient({
    required NearbyServiceMessagesListener socketListener,
    required NearbyConnectionAndroidInfo info,
  }) async {
    if (state.value.isLoading) {
      final response = await _network.pingServer(
        address: info.ownerIpAddress,
        port: _androidData.port,
      );

      if (await _pingManager.checkPong(response)) {
        try {
          _socket = await _network.connectToSocket(
            ownerIpAddress: info.ownerIpAddress,
            port: _androidData.port,
            socketType: NearbySocketType.message,
          );
          _createSocketSubscription(socketListener);
          return;
        } catch (e) {
          Logger.error(e);
        }
      }

      Logger.debug(
        'Retry to connect to the server in ${_androidData.clientReconnectInterval.inSeconds}s',
      );
      Future.delayed(_androidData.clientReconnectInterval, () {
        _tryConnectClient(
          socketListener: socketListener,
          info: info,
        );
      });
    }
  }

  Future<void> _startServerSubscription({
    required NearbyServiceMessagesListener socketListener,
    required NearbyConnectionAndroidInfo info,
  }) async {
    _server = await _network.startServer(
      ownerIpAddress: info.ownerIpAddress,
      port: _androidData.port,
    );
    _server?.listen(
      (request) async {
        _androidData.serverListener?.call(request);
        final isPing = await _pingManager.checkPing(request);
        if (isPing) {
          Logger.debug('Server got ping request');
          _network.pongClient(request);
          return;
        }

        if (request.uri.path == _Urls.ws) {
          final type = NearbySocketType.fromRequest(request);
          if (type == NearbySocketType.message) {
            _socket = await WebSocketTransformer.upgrade(request);
            _createSocketSubscription(socketListener);
          } else {
            _fileSocketsManager.onWsRequest(request);
          }
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
          Logger.error('Got unknown request ${request.requestedUri}');
        }
      },
    );
  }

  // void _createSocketSubscription(NearbyServiceMessagesListener socketListener) {
  //   Logger.debug('Starting socket subscription');

  //   if (_connectedDeviceId != null) {
  //     _messagesSubscription = _socket
  //         ?.where((e) => e != null)
  //         .listen(
  //       (binaryData) async {
  //         try {
  //           Logger.debug('Received binary data: $binaryData');
  //           final jsonString = utf8.decode(binaryData);
  //           final Map<String, dynamic> jsonData = jsonDecode(jsonString);
  //           final content = NearbyMessageContent.fromJson(jsonData['content']);
  //           final sender = NearbyDeviceInfo.fromJson(jsonData['sender']);
  //           final receivedMessage = ReceivedNearbyMessage(
  //             content: content,
  //             sender: sender,
  //           );
  //           _handleFilesMessage(receivedMessage);
  //           socketListener.onData(receivedMessage);
  //         } catch (e) {
  //           Logger.error(e);
  //         }
  //       },
  //       onDone: () {
  //         state.add(CommunicationChannelState.notConnected);
  //         socketListener.onDone?.call();
  //       },
  //       onError: (e, s) {
  //         Logger.error(e);
  //         state.add(CommunicationChannelState.notConnected);
  //         socketListener.onError?.call(e, s);
  //       },
  //       cancelOnError: socketListener.cancelOnError,
  //     );
  //   }
  // }

/// for encryption, we can utilize the following
void _createSocketSubscription(NearbyServiceMessagesListener socketListener, [String? myId]) {
  Logger.debug('Starting socket subscription');

  if (_connectedDeviceId != null) {
    _messagesSubscription = _socket
        ?.where((e) => e != null)
        .listen(
      (binaryData) async {
        try {
          Logger.debug('Received encrypted data: $binaryData');

          // Decrypt the binary data
          final key = Key.fromUtf8('iBayanihan' * 4);

          final iv = IV.fromUtf8('iBayanihan' * 4);
          final encrypter = Encrypter(AES(key));

          final decrypted = encrypter.decrypt(binaryData, iv: iv);

          final jsonString = utf8.decode(decrypted);

          Logger.debug('Received decrypted data: $jsonString');

          final Map<String, dynamic> jsonData = jsonDecode(jsonString);
          final content = NearbyMessageContent.fromJson(jsonData['content']);
          final sender = NearbyDeviceInfo.fromJson(jsonData['sender']);
          final receivedMessage = ReceivedNearbyMessage(
            content: content,
            sender: sender,
          );
          _handleFilesMessage(receivedMessage);
          socketListener.onData(receivedMessage);
        } catch (e) {
          Logger.error(e);
        }
      },
      onDone: () {
        state.add(CommunicationChannelState.notConnected);
        socketListener.onDone?.call();
      },
      onError: (e, s) {
        Logger.error(e);
        state.add(CommunicationChannelState.notConnected);
        socketListener.onError?.call(e, s);
      },
      cancelOnError: socketListener.cancelOnError,
    );
  }
}

  void _handleFilesMessage(NearbyMessage message) {
    if (message.content is NearbyMessageFilesRequest ||
        message.content is NearbyMessageFilesResponse) {
      _fileSocketsManager.handleFileMessageContent(
        message.content,
        isReceived: message is ReceivedNearbyMessage,
        sender: message is ReceivedNearbyMessage ? message.sender : null,
      );
    }
  }
}
