import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

class CallPage extends StatefulWidget {
  final String peerId;
  final bool isCaller;
  final Map<String, dynamic>? initialOffer;

  const CallPage({
    super.key,
    required this.peerId,
    required this.isCaller,
    this.initialOffer,
  });

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final _supabase = Supabase.instance.client;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RealtimeChannel? _signalingChannel;
  bool _isCallActive = false;
  String? _callRecordId;
  String? _myProfileName;
  String? _myProfilePhone;

  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _isSpeakerOn = false;

  late String _myId;

  // ICE Candidates queueing to prevent drop
  final List<RTCIceCandidate> _localCandidates = [];
  bool _answerReceived = false;
  final List<RTCIceCandidate> _remoteCandidatesQueue = [];
  bool _isRemoteDescriptionSet = false;

  final Map<String, dynamic> config = {
    "sdpSemantics": "unified-plan",
    "iceServers": [
      {
        "urls": [
          "stun:stun.l.google.com:19302",
          "stun:stun1.l.google.com:19302",
          "stun:stun2.l.google.com:19302",
          "stun:stun3.l.google.com:19302",
          "stun:stun4.l.google.com:19302",
        ],
      },
    ],
  };

  @override
  void initState() {
    super.initState();
    _myId = _supabase.auth.currentUser!.id;
    _fetchMyProfile();
    init();
  }

  Future<void> _fetchMyProfile() async {
    try {
      final res = await _supabase
          .from('profiles')
          .select('name, phone')
          .eq('id', _myId)
          .single();
      _myProfileName = res['name'];
      _myProfilePhone = res['phone'];
    } catch (_) {}
  }

  bool _hasStartedCall = false;

  Future<void> init() async {
    await _remoteRenderer.initialize();
    Helper.setSpeakerphoneOn(_isSpeakerOn);
    await _openMedia();

    // If the user denied microphone access on an Android phone, abort the call completely instead of a fatal crash
    if (_localStream == null) {
      _hangUp(remoteHangup: false);
      return;
    }

    await _createConnection();
    _connectSignaling();
  }

  Future<void> _onSignalingReady() async {
    if (_hasStartedCall) return;
    _hasStartedCall = true;

    if (widget.isCaller) {
      debugPrint('Signaling: Initiating call to ${widget.peerId}');
      // Ensure profile data is loaded if possible
      if (_myProfileName == null) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await _createOffer();
      await _recordCallToDb();
    } else if (widget.initialOffer != null) {
      debugPrint('Signaling: Handling incoming offer from ${widget.peerId}');
      // The peer connection might still be initializing media
      await Future.delayed(const Duration(milliseconds: 800));
      await _handleOffer(widget.initialOffer!);
    }
  }

  Future<void> _recordCallToDb() async {
    try {
      final res = await _supabase
          .from('call_history')
          .insert({
            'caller_id': _myId,
            'callee_id': widget.peerId,
            'status': 'started',
          })
          .select()
          .single();
      _callRecordId = res['id'].toString();
    } catch (e) {
      debugPrint('Error recording call history: $e');
    }
  }

  Future<void> _endCallInDb() async {
    if (_callRecordId != null) {
      try {
        await _supabase
            .from('call_history')
            .update({'status': 'ended'})
            .eq('id', _callRecordId!);
      } catch (e) {
        debugPrint('Error updating call history: $e');
      }
    }
  }

  Future<void> _openMedia() async {
    try {
      // Only Audio for this app
      _localStream = await navigator.mediaDevices.getUserMedia({
        "audio": true,
        "video": false, // explicitly false
      });
    } catch (e) {
      debugPrint('Error accessing microphone: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Microphone permission is required to make calls. Details: $e',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _createConnection() async {
    _peerConnection = await createPeerConnection(config);

    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    _peerConnection!.onAddStream = (stream) {
      setState(() {
        _remoteRenderer.srcObject = stream;
      });
    };

    _peerConnection!.onTrack = (event) async {
      if (event.streams.isNotEmpty) {
        setState(() {
          _remoteRenderer.srcObject = event.streams[0];
        });
      }
    };

    _peerConnection!.onIceCandidate = (candidate) {
      if (widget.isCaller && !_answerReceived) {
        _localCandidates.add(candidate);
      } else {
        _sendSignal("call_candidate", {
          "candidate": candidate.candidate,
          "sdpMid": candidate.sdpMid,
          "sdpMLineIndex": candidate.sdpMLineIndex,
        });
      }
    };

    _peerConnection!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() => _isCallActive = true);
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _hangUp();
      }
    };

    _peerConnection!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        setState(() => _isCallActive = true);
      } else if (state ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _hangUp();
      }
    };
  }

  void _connectSignaling() {
    // Send signals to PEER_ID, but listen on MY_ID
    // To keep it simple, we use two separate channel references
    _signalingChannel = _supabase.channel('signaling:$_myId');

    _signalingChannel!
        .onBroadcast(
          event: 'call_answer',
          callback: (payload) async {
            debugPrint('SIGNAL: Received call_answer');
            final data = payload['payload'] ?? payload;
            await _handleAnswer(data);
          },
        )
        .onBroadcast(
          event: 'call_candidate',
          callback: (payload) async {
            debugPrint('SIGNAL: Received call_candidate');
            final data = payload['payload'] ?? payload;
            await _handleCandidate(data);
          },
        )
        .onBroadcast(
          event: 'call_end',
          callback: (payload) async {
            debugPrint('SIGNAL: Received call_end');
            _hangUp(remoteHangup: true);
          },
        )
        .subscribe((status, error) async {
          debugPrint('My signaling channel status: $status');
          if (status == RealtimeSubscribeStatus.subscribed) {
            await Future.delayed(const Duration(milliseconds: 500));
            _onSignalingReady();
          }
        });
  }

  void _sendSignal(String event, dynamic payloadData) async {
    // Create a temporary channel to PUSH to the peer's inbox
    final peerChannel = _supabase.channel('signaling:${widget.peerId}');
    
    // We don't need to subscribe to push a broadcast
    await peerChannel.sendBroadcastMessage(
      event: event,
      payload: {
        "caller": _myId,
        "data": payloadData,
      },
    );
    _supabase.removeChannel(peerChannel);
  }

  Future<void> _createOffer() async {
    final offer = await _peerConnection!.createOffer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
      'optional': [],
    });
    await _peerConnection!.setLocalDescription(offer);

    await Future.delayed(const Duration(milliseconds: 500));

    debugPrint('SIGNAL: Pushing call_offer to signaling:${widget.peerId}');
    final peerChannel = _supabase.channel('signaling:${widget.peerId}');
    await peerChannel.sendBroadcastMessage(
      event: 'call_offer',
      payload: {
        "target": widget.peerId,
        "caller": _myId,
        "caller_name": _myProfileName ?? "Call from $_myId",
        "caller_phone": _myProfilePhone ?? "Unknown",
        "data": offer.toMap(),
      },
    );
    _supabase.removeChannel(peerChannel);
  }

  Future<void> _handleOffer(Map<String, dynamic> payload) async {
    final sdpMap = payload['data'];
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdpMap['sdp'], sdpMap['type']),
    );

    _isRemoteDescriptionSet = true;
    for (var c in _remoteCandidatesQueue) {
      await _peerConnection!.addCandidate(c);
    }
    _remoteCandidatesQueue.clear();

    final answer = await _peerConnection!.createAnswer({
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
      'optional': [],
    });
    await _peerConnection!.setLocalDescription(answer);

    _sendSignal('call_answer', answer.toMap());
  }

  Future<void> _handleAnswer(Map<String, dynamic> payload) async {
    final sdpMap = payload['data'];
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdpMap['sdp'], sdpMap['type']),
    );

    _isRemoteDescriptionSet = true;
    for (var c in _remoteCandidatesQueue) {
      await _peerConnection!.addCandidate(c);
    }
    _remoteCandidatesQueue.clear();

    _answerReceived = true;
    for (var candidate in _localCandidates) {
      _sendSignal("call_candidate", {
        "candidate": candidate.candidate,
        "sdpMid": candidate.sdpMid,
        "sdpMLineIndex": candidate.sdpMLineIndex,
      });
    }
    _localCandidates.clear();
  }

  Future<void> _handleCandidate(Map<String, dynamic> payload) async {
    final cMap = payload['data'];
    final candidate = RTCIceCandidate(
      cMap['candidate'],
      cMap['sdpMid'],
      cMap['sdpMLineIndex'],
    );

    if (_isRemoteDescriptionSet) {
      await _peerConnection!.addCandidate(candidate);
    } else {
      _remoteCandidatesQueue.add(candidate);
    }
  }

  void _hangUp({bool remoteHangup = false}) async {
    if (!remoteHangup) {
      _sendSignal('call_end', {});
    }
    if (widget.isCaller) {
      await _endCallInDb();
    }
    
    // Clear CallKit for the receiver
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {}

    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _localStream?.getTracks().forEach((track) {
      track.stop();
    });
    _peerConnection?.dispose();
    _signalingChannel?.unsubscribe();
    _remoteRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.teal.shade900,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.record_voice_over, size: 100, color: Colors.white),
            const SizedBox(height: 30),
            Text(
              _isCallActive ? "Call in progress" : "Connecting...",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Peer ID: ${widget.peerId.length > 8 ? widget.peerId.substring(0, 8) : widget.peerId}",
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 60),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                InkWell(
                  onTap: () {
                    setState(() {
                      _isSpeakerOn = !_isSpeakerOn;
                    });
                    Helper.setSpeakerphoneOn(_isSpeakerOn);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _isSpeakerOn ? Colors.white : Colors.teal.shade700,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                      size: 32,
                      color: _isSpeakerOn ? Colors.teal.shade900 : Colors.white,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => _hangUp(),
                  child: Container(
                    height: 80,
                    width: 80,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.call_end,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 64),
              ],
            ),
            SizedBox(width: 0, height: 0, child: RTCVideoView(_remoteRenderer)),
          ],
        ),
      ),
    );
  }
}
