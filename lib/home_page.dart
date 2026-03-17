import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:uuid/uuid.dart';
import 'package:permission_handler/permission_handler.dart';
import 'call_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _profiles = [];
  bool _isLoading = true;
  RealtimeChannel? _signalingChannel;
  Timer? _heartbeatTimer;
  Timer? _uiRefreshTimer;
  bool _ownStatusUpdateFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _fetchProfiles();
    _initSignaling();
    _startHeartbeat();
    _listenToCallKitEvents();
    _listenToProfiles();
    _startUiRefreshTimer();
  }

  void _listenToProfiles() {
    _supabase.from('profiles').stream(primaryKey: ['id']).listen((data) {
      if (mounted) {
        final user = _supabase.auth.currentUser;
        if (user == null) return;
        final myId = user.id.toLowerCase();
        
        setState(() {
          // Filter out current user using case-insensitive comparison
          _profiles = data.where((p) => p['id'].toString().toLowerCase() != myId).toList();
          _isLoading = false;
        });
        debugPrint('Stream updated: ${_profiles.length} other profiles found.');
      }
    });
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.notification,
    ].request();
    
    // For Android 14+ full screen intent doesn't need runtime request but 
    // it's good to ensure the user knows.
  }

  Future<void> _fetchProfiles() async {
    try {
      final myId = _supabase.auth.currentUser!.id;

      // 2. Fetch all profiles except mine
      final res = await _supabase.from('profiles').select();
      final allProfiles = List<Map<String, dynamic>>.from(res)
          .where((p) => p['id'].toString().toLowerCase() != myId.toLowerCase())
          .toList();

      setState(() {
        _profiles = allProfiles; 
      });
    } catch (e) {
      debugPrint('Error fetching profiles: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _startHeartbeat() {
    // Initial update
    _updateStatus(true);
    
    // FAST Heartbeat every 3 seconds for immediate detection
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _updateStatus(true);
    });
  }

  void _startUiRefreshTimer() {
    // Refresh UI every 5 seconds
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _updateStatus(bool isOnline) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;
      
      final myId = user.id;
      final data = {
        'last_seen': DateTime.now().toUtc().toIso8601String(),
        'is_online': isOnline,
      };

      // Try update first
      final response = await _supabase.from('profiles').update(data).eq('id', myId).select();
      
      if (response.isEmpty) {
        debugPrint('Profile not found for $myId, attempting to create it...');
        // Fallback: If update failed because record doesn't exist, try insert
        try {
          await _supabase.from('profiles').insert({
            'id': myId,
            'email': user.email,
            'name': user.userMetadata?['name'] ?? 'User',
            'phone': user.userMetadata?['phone'] ?? 'Unknown',
            'role': user.userMetadata?['role'] ?? 'user',
            ...data,
          });
          setState(() => _ownStatusUpdateFailed = false);
          debugPrint('Profile created successfully via fallback.');
        } catch (insertError) {
          setState(() => _ownStatusUpdateFailed = true);
          debugPrint("CORE ERROR: Could not sync profile to Database. This is usually an RLS or Table issue: $insertError");
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Auth successful, but profile setup failed: $insertError')),
            );
          }
        }
      } else {
        setState(() => _ownStatusUpdateFailed = false);
        debugPrint('SUCCESS: My status updated to ${isOnline ? "Online" : "Offline"}');
      }
    } catch (e) {
      setState(() => _ownStatusUpdateFailed = true);
      debugPrint('CRITICAL: Error updating status: $e');
    }
  }

  bool _isUserOnline(Map<String, dynamic> profile) {
    final lastSeenStr = profile['last_seen'];
    if (lastSeenStr == null) return profile['is_online'] == true;
    
    try {
      final normalizedStr = lastSeenStr.toString().replaceAll(' ', 'T');
      final lastSeen = DateTime.parse(normalizedStr).toUtc();
      final now = DateTime.now().toUtc();
      final difference = now.difference(lastSeen).inSeconds.abs();
      
      // EXTREMELY STRICT: If we haven't seen them in 10 seconds, they are offline.
      return (profile['is_online'] == true) && (difference < 10);
    } catch (e) {
      return profile['is_online'] == true;
    }
  }

  void _initSignaling() {
    final myId = _supabase.auth.currentUser!.id;
    // TARGETED CHANNEL: Each user listens for their OWN Id
    _signalingChannel = _supabase.channel('signaling:$myId');

    _signalingChannel!
        .onBroadcast(
          event: 'call_offer',
          callback: (payload) {
            debugPrint('Received private call_offer signal');
            final data = payload['payload'] ?? payload;
            
            // BUSY CHECK: If we are already on another page (dialing or in call),
            // tell the caller we are busy.
            if (ModalRoute.of(context)?.isCurrent != true) {
               _sendBusySignal(data);
               return;
            }
            
            _showCallKitIncoming(data);
          },
        )
        .subscribe((status, error) {
          debugPrint('My signaling inbox ($myId) status: $status');
        });
  }

  Future<void> _showCallKitIncoming(Map<String, dynamic> offerPayload) async {
    if (!mounted) return;
    final callId = const Uuid().v4();
    final callerName = offerPayload['caller_name'] ?? 'Someone';
    
    final params = CallKitParams(
      id: callId,
      nameCaller: callerName,
      appName: 'RTC Call',
      handle: offerPayload['caller_phone'] ?? 'Audio Call',
      type: 0, // Audio
      duration: 30000,
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#075E54',
        actionColor: '#4CAF50',
      ),
      ios: const IOSParams(
        iconName: 'AppIcon',
        handleType: 'generic',
        supportsVideo: false,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
      ),
      extra: offerPayload,
    );

    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  StreamSubscription? _callKitSubscription;

  void _listenToCallKitEvents() {
    _callKitSubscription = FlutterCallkitIncoming.onEvent.listen((event) {
      if (!mounted) return;
      
      // Prevent pushing CallPage if we are already in one
      // or if another call action is in progress
      if (ModalRoute.of(context)?.isCurrent != true) {
        debugPrint('Already in another page, skipping CallKit event');
        return;
      }

      switch (event!.event) {
        case Event.actionCallAccept:
          final offerPayload = Map<String, dynamic>.from(event.body['extra']);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CallPage(
                peerId: offerPayload['caller'],
                isCaller: false,
                initialOffer: offerPayload,
                callSessionId: offerPayload['session_id'],
              ),
            ),
          );
          break;
        case Event.actionCallDecline:
        case Event.actionCallTimeout:
          final extra = Map<String, dynamic>.from(event.body['extra']);
          _sendRejectionSignal(extra);
          break;
        default:
          break;
      }
    });
  }

  void _sendBusySignal(Map<String, dynamic> offerPayload) {
    final sessionId = offerPayload['session_id'];
    if (sessionId == null) return;

    final channel = _supabase.channel('call_session:$sessionId');
    channel.sendBroadcastMessage(
      event: 'call_busy',
      payload: {
        "caller": _supabase.auth.currentUser!.id,
        "data": {"reason": "busy"}
      },
    );
    // Cleanup
    Future.delayed(const Duration(seconds: 1), () {
      _supabase.removeChannel(channel);
    });
  }

  void _sendRejectionSignal(Map<String, dynamic> offerPayload) {
    final sessionId = offerPayload['session_id'];
    if (sessionId == null) return;

    final channel = _supabase.channel('call_session:$sessionId');
    channel.sendBroadcastMessage(
      event: 'call_end',
      payload: {
        "caller": _supabase.auth.currentUser!.id,
        "data": {"reason": "declined"}
      },
    );
    // Cleanup
    Future.delayed(const Duration(seconds: 1), () {
      _supabase.removeChannel(channel);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came to foreground, refresh everything
      _updateStatus(true);
      _fetchProfiles();
    } else if (state == AppLifecycleState.detached) {
      // App is being closed - set to offline
      _updateStatus(false);
    }
    // We don't set to offline on 'paused' (background) anymore 
    // to allow heartbeat/background tasks to keep the user online.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatTimer?.cancel();
    _uiRefreshTimer?.cancel();
    _signalingChannel?.unsubscribe();
    _callKitSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Contacts', style: TextStyle(fontSize: 18)),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _ownStatusUpdateFailed ? 'You: Status Error (Check RLS)' : 'You: Online',
                  style: TextStyle(
                    fontSize: 12, 
                    color: _ownStatusUpdateFailed ? Colors.red : Colors.green,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => _fetchProfiles(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Contacts',
          ),
          IconButton(
            onPressed: () => _supabase.auth.signOut(),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign Out',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
              ? const Center(child: Text('No contacts found'))
              : RefreshIndicator(
                  onRefresh: _fetchProfiles,
                  child: ListView.builder(
                    itemCount: _profiles.length,
                    itemBuilder: (context, index) {
                      final profile = _profiles[index];
                      final isOnline = _isUserOnline(profile);
                      return ListTile(
                        leading: Stack(
                          children: [
                            CircleAvatar(
                              child:
                                  Text(profile['name']?.substring(0, 1) ?? 'U'),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: isOnline ? Colors.green : Colors.grey,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                          ],
                        ),
                        title: Text(
                          profile['name'] ?? profile['phone'] ?? 'Unknown User',
                        ),
                        subtitle: Text(
                          '${profile['role'] ?? 'user'} • ${isOnline ? "Online" : "Offline"}',
                          style: TextStyle(
                            color: isOnline ? Colors.green.shade700 : Colors.grey,
                            fontWeight: isOnline ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        trailing: IconButton(
                          icon: Icon(Icons.call,
                              color: isOnline ? Colors.teal : Colors.grey),
                          onPressed: isOnline
                              ? () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => CallPage(
                                          peerId: profile['id'], isCaller: true),
                                    ),
                                  );
                                }
                              : () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('User is offline.')),
                                  );
                                },
                        ),
                      );
                    },
                  ),
                ),

      floatingActionButton: FloatingActionButton(
        onPressed: _showDialDialog,
        backgroundColor: Colors.teal,
        child: const Icon(Icons.dialpad),
      ),
    );
  }

  void _showDialDialog() {
    final phoneController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Call by Number'),
        content: TextField(
          controller: phoneController,
          decoration: const InputDecoration(
            labelText: 'Phone Number',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone),
          ),
          keyboardType: TextInputType.phone,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _callByPhoneNumber(phoneController.text.trim());
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            child: const Text('Call', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _callByPhoneNumber(String phoneNumber) async {
    if (phoneNumber.isEmpty) return;

    try {
      final res = await _supabase
          .from('profiles')
          .select()
          .eq('phone', phoneNumber)
          .maybeSingle();

      if (res != null) {
        if (!_isUserOnline(res)) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('User is offline.')),
          );
          return;
        }

        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallPage(peerId: res['id'], isCaller: true),
          ),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This number is not registered.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error finding user: $e')));
    }
  }
}


