import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nearby_service/nearby_service.dart';
import 'package:nearby_service/src/utils/file_socket.dart';
import 'package:nearby_service/src/utils/listenable.dart';
import 'package:nearby_service/src/utils/logger.dart';
import 'package:nearby_service/src/utils/random.dart';
import 'package:nearby_service/src/utils/stream_mapper.dart';

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
  /// Adds [OutgoingNearbyMessage]'s JSON representation to the [_socket].
  ///
  Future<bool> send(OutgoingNearbyMessage message) async {
    if (message.isValid) {
      Logger.debug('Socket: $_socket');
      Logger.debug('Message: $message');
      Logger.debug('Message receiver id: ${message.receiver.id}');
      Logger.debug('Connected device id: $_connectedDeviceId');
      if (_socket != null && message.receiver.id == _connectedDeviceId) {
        final sender = await _service.getCurrentDeviceInfo();
        if (sender != null) {
          try {
            _socket!.add(
              jsonEncode(
                {
                  'content': message.content.toJson(),
                  'sender': sender.toJson(),
                },
              ),
            );
            _handleFilesMessage(message);
          } catch (e) {
            Logger.error(e);
          }
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

  // receive the data from the socket
  void _createSocketSubscription(NearbyServiceMessagesListener socketListener) {
  Logger.debug('Starting socket subscription');

  if (_connectedDeviceId != null) {
    _messagesSubscription = _socket
        ?.where((e) => e != null)
        .map(MessagesStreamMapper.toMessage)
        .cast<ReceivedNearbyMessage>()
        .map((e) => MessagesStreamMapper.replaceId(e, _connectedDeviceId))
        .listen(
      (message) async {
        try {
          // Log the entire message for debugging
          Logger.debug('Received message: $message');


          _handleFilesMessage(message);
          socketListener.onData(message);
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
  if (_messagesSubscription != null) {
    state.add(CommunicationChannelState.connected);
    Logger.info('Socket subscription was created successfully');
    socketListener.onCreated?.call();
  } else {
    state.add(CommunicationChannelState.notConnected);
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

// import 'dart:async';
// import 'dart:convert';
// import 'dart:io';
// import 'dart:typed_data';

// import 'package:flutter/foundation.dart';
// import 'package:nearby_service/nearby_service.dart';
// import 'package:nearby_service/src/utils/file_socket.dart';
// import 'package:nearby_service/src/utils/listenable.dart';
// import 'package:nearby_service/src/utils/logger.dart';
// import 'package:nearby_service/src/utils/random.dart';
// import 'package:nearby_service/src/utils/stream_mapper.dart';

// import 'package:cryptography/cryptography.dart';
// import 'package:crypto/crypto.dart';
// import 'package:encrypt/encrypt.dart' as encrypt;

// part 'ping_manager.dart';

// part 'network.dart';

// part 'file_sockets_manager.dart';

// ///
// /// A service for creating a communication channel on the Android platform.
// ///
// class NearbySocketService {
//   NearbySocketService(this._service);

//   final NearbyAndroidService _service;
//   final _pingManager = NearbySocketPingManager();
//   final _network = NearbyServiceNetwork();
//   late final _fileSocketsManager = FileSocketsManager(
//     _network,
//     _service,
//     _pingManager,
//   );

//   late final state = NearbyServiceListenable<CommunicationChannelState>(
//     initialValue: CommunicationChannelState.notConnected,
//   );

//   NearbyAndroidCommunicationChannelData _androidData =
//       const NearbyAndroidCommunicationChannelData();

//   String? _connectedDeviceId;
//   WebSocket? _socket;
//   HttpServer? _server;
//   StreamSubscription? _messagesSubscription;

//   final _key = encrypt.Key.fromUtf8('my 32 length key................');
//   final _iv = encrypt.IV.fromUtf8('my 16 length iv.');

//   CommunicationChannelState get communicationChannelStateValue => state.value;

//   ValueListenable<CommunicationChannelState> get communicationChannelState =>
//       state.notifier;

//   ///
//   /// Start a socket with the user's role defined.
//   /// If he is the owner of the group, he becomes a server.
//   /// Otherwise, he becomes a client.
//   ///
//   /// * The server starts up and waits for a request from the
//   /// client to establish a connection.
//   /// * The client pings the server until he receives a pong.
//   /// When he does, he tries to connect to the server.
//   ///
//   Future<bool> startSocket({
//     required NearbyCommunicationChannelData data,
//   }) async {
//     state.add(CommunicationChannelState.loading);

//     _androidData = data.androidData;
//     _connectedDeviceId = data.connectedDeviceId;

//     _fileSocketsManager
//       ..setListener(data.filesListener)
//       ..setConnectionData(data.androidData);

//     final info = await _service.getConnectionInfo();

//     if (info != null && info.groupFormed) {
//       if (info.isGroupOwner) {
//         await _startServerSubscription(
//           socketListener: data.messagesListener,
//           info: info,
//         );
//         return true;
//       } else {
//         await _tryConnectClient(
//           socketListener: data.messagesListener,
//           info: info,
//         );
//         return true;
//       }
//     } else {
//       Future.delayed(data.androidData.clientReconnectInterval, () {
//         startSocket(data: data);
//       });
//       return false;
//     }
//   }

//   ///
//   /// Adds [OutgoingNearbyMessage]'s binary representation to the [_socket].
//   ///
//   Future<bool> send(OutgoingNearbyMessage message) async {
//     Logger.debug(' ===================== Socket: $_socket');
//     if (message.isValid) {
//       if (_socket != null && message.receiver.id == _connectedDeviceId) {
//         final sender = await _service.getCurrentDeviceInfo();
//         if (sender != null) {
//           final jsonString = jsonEncode({
//             'content': message.content.toJson(),
//             'sender': sender.toJson(),
//           });

//           final binaryData = Uint8List.fromList(utf8.encode(jsonString));
//           Logger.debug('Sending binary data: $binaryData');
//           _socket!.add(binaryData);
//           _handleFilesMessage(message);
//         }
//         return true;
//       }
//       return false;
//     } else {
//       throw NearbyServiceException.invalidMessage(message.content);
//     }
//   }
//   /// for encryption, we can utilize the following

//   // Future<bool> send(OutgoingNearbyMessage message) async {
//   //   if (message.isValid) {
//   //     Logger.debug('Sending message: $message');

//   //     Logger.debug('Message receiver id: ${message.receiver.id}');

//   //     Logger.debug('Connected device id: $_connectedDeviceId');

//   //     // check if there is socket
//   //     Logger.debug('Socket: $_socket');

//   //     if (_socket != null && message.receiver.id == _connectedDeviceId) {
//   //       final sender = await _service.getCurrentDeviceInfo();
//   //       Logger.debug('Sender: $sender');
//   //       Logger.debug('Message: ${message.content.toJson()}');
//   //       if (sender != null) {
//   //         final jsonString = jsonEncode({
//   //           'content': message.content.toJson(),
//   //           'sender': sender.toJson(),
//   //         });

//   //         Logger.debug('Sending json data: $jsonString');

//   //         // Encrypt the JSON string using the provided encryptAES method
//   //         final encrypter = encrypt.Encrypter(encrypt.AES(_key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'));
//   //         final encrypted = encrypter.encrypt(jsonString, iv: _iv);

//   //         Logger.debug('Sending encrypted data: ${encrypted.bytes}');

//   //         _socket!.add(encrypted.bytes);
//   //         _handleFilesMessage(message);
//   //       } else {
//   //         Logger.error('Failed to retrieve sender info');
//   //       }
//   //       return true;
//   //     }
//   //     return false;
//   //   } else {
//   //     throw NearbyServiceException.invalidMessage(message.content);
//   //   }
//   // }


//   ///
//   /// Turns off [_messagesSubscription] and [_socket].
//   ///
//   Future<bool> cancel() async {
//     try {
//       await _messagesSubscription?.cancel();
//       await _fileSocketsManager.closeAll();

//       _messagesSubscription = null;
//       _socket?.close();
//       _socket = null;
//       _server?.close(force: true);
//       _server = null;
//       _connectedDeviceId = null;

//       state.add(CommunicationChannelState.notConnected);
//       return true;
//     } catch (e) {
//       return false;
//     }
//   }

//   Future<void> _tryConnectClient({
//     required NearbyServiceMessagesListener socketListener,
//     required NearbyConnectionAndroidInfo info,
//   }) async {
//     if (state.value.isLoading) {
//       final response = await _network.pingServer(
//         address: info.ownerIpAddress,
//         port: _androidData.port,
//       );

//       if (await _pingManager.checkPong(response)) {
//         try {
//           _socket = await _network.connectToSocket(
//             ownerIpAddress: info.ownerIpAddress,
//             port: _androidData.port,
//             socketType: NearbySocketType.message,
//           );
//           _createSocketSubscription(socketListener);
//           return;
//         } catch (e) {
//           Logger.error(e);
//         }
//       }

//       Logger.debug(
//         'Retry to connect to the server in ${_androidData.clientReconnectInterval.inSeconds}s',
//       );
//       Future.delayed(_androidData.clientReconnectInterval, () {
//         _tryConnectClient(
//           socketListener: socketListener,
//           info: info,
//         );
//       });
//     }
//   }

//   Future<void> _startServerSubscription({
//     required NearbyServiceMessagesListener socketListener,
//     required NearbyConnectionAndroidInfo info,
//   }) async {
//     _server = await _network.startServer(
//       ownerIpAddress: info.ownerIpAddress,
//       port: _androidData.port,
//     );
//     _server?.listen(
//       (request) async {
//         _androidData.serverListener?.call(request);
//         final isPing = await _pingManager.checkPing(request);
//         if (isPing) {
//           Logger.debug('Server got ping request');
//           _network.pongClient(request);
//           return;
//         }

//         if (request.uri.path == _Urls.ws) {
//           final type = NearbySocketType.fromRequest(request);
//           if (type == NearbySocketType.message) {
//             _socket = await WebSocketTransformer.upgrade(request);
//             _createSocketSubscription(socketListener);
//           } else {
//             _fileSocketsManager.onWsRequest(request);
//           }
//         } else {
//           request.response
//             ..statusCode = HttpStatus.notFound
//             ..close();
//           Logger.error('Got unknown request ${request.requestedUri}');
//         }
//       },
//     );
//   }

//   // void _createSocketSubscription(NearbyServiceMessagesListener socketListener) {
//   //   Logger.debug('Starting socket subscription');

//   //   if (_connectedDeviceId != null) {
//   //     _messagesSubscription = _socket
//   //         ?.where((e) => e != null)
//   //         .listen(
//   //       (binaryData) async {
//   //         try {
//   //           Logger.debug('Received binary data: $binaryData');
//   //           final jsonString = utf8.decode(binaryData);
//   //           final Map<String, dynamic> jsonData = jsonDecode(jsonString);
//   //           final content = NearbyMessageContent.fromJson(jsonData['content']);
//   //           final sender = NearbyDeviceInfo.fromJson(jsonData['sender']);
//   //           final receivedMessage = ReceivedNearbyMessage(
//   //             content: content,
//   //             sender: sender,
//   //           );
//   //           _handleFilesMessage(receivedMessage);
//   //           socketListener.onData(receivedMessage);
//   //         } catch (e) {
//   //           Logger.error(e);
//   //         }
//   //       },
//   //       onDone: () {
//   //         state.add(CommunicationChannelState.notConnected);
//   //         socketListener.onDone?.call();
//   //       },
//   //       onError: (e, s) {
//   //         Logger.error(e);
//   //         state.add(CommunicationChannelState.notConnected);
//   //         socketListener.onError?.call(e, s);
//   //       },
//   //       cancelOnError: socketListener.cancelOnError,
//   //     );
//   //   }
//   // }

//   // for encryption, we can utilize the following
//   void _createSocketSubscription(NearbyServiceMessagesListener socketListener) {
//     Logger.debug('Starting socket subscription');

//     if (_connectedDeviceId != null) {
//       _messagesSubscription = _socket
//           ?.where((e) => e != null)
//           .listen(
//         (binaryData) async {
//           try {
//             Logger.debug('Received encrypted data: $binaryData');

//             // Decrypt the binary data
//             final encrypter = encrypt.Encrypter(encrypt.AES(_key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'));
//             final decrypted = encrypter.decrypt(encrypt.Encrypted(Uint8List.fromList(binaryData)), iv: _iv);

//             Logger.debug('Received decrypted data: $decrypted');

//             final Map<String, dynamic> jsonData = jsonDecode(decrypted);
//             final content = NearbyMessageContent.fromJson(jsonData['content']);
//             final sender = NearbyDeviceInfo.fromJson(jsonData['sender']);
//             Logger.debug('Received sender info: ${sender.toJson()}');
//             final receivedMessage = ReceivedNearbyMessage(
//               content: content,
//               sender: sender,
//             );
//             _handleFilesMessage(receivedMessage);
//             socketListener.onData(receivedMessage);
//           } catch (e) {
//             Logger.error('Error during decryption: $e');
//           }
//         },
//       );
//     }
//   }

//   void _handleFilesMessage(NearbyMessage message) {
//     if (message.content is NearbyMessageFilesRequest ||
//         message.content is NearbyMessageFilesResponse) {
//       _fileSocketsManager.handleFileMessageContent(
//         message.content,
//         isReceived: message is ReceivedNearbyMessage,
//         sender: message is ReceivedNearbyMessage ? message.sender : null,
//       );
//     }
//   }
// }
