import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:grow_logix_admin/Log_In.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ⭐ SAFE: only import platform-specific packages on desktop
// (prevents tree-shaking issues when the .exe is built for Windows)
import 'package:window_manager/window_manager.dart' as wm;
import 'package:screen_retriever/screen_retriever.dart' as sr;

const String baseUrl = 'https://goldenrod-raven-866091.hostingersite.com/manage_manager.php';
const String liveStreamUrl = 'https://goldenrod-raven-866091.hostingersite.com/live_stream.php';
const String autoPasswordUrl = 'https://goldenrod-raven-866091.hostingersite.com/create_auto_password.php';

const List<String> availableRoleChoices = [
  'Website Developer',
  'Video Editor',
  'Social Media Executive',
  'SEO Executive',
  'Data Scrapper',
  'Graphics Designer',
];

// Isolated background function for non-blocking base64 decoding
Uint8List _decodeBase64Task(String input) {
  try {
    return base64Decode(input);
  } catch (_) {
    return Uint8List(0);
  }
}

class ManagerDashboard extends StatefulWidget {
  const ManagerDashboard({super.key});

  @override
  State<ManagerDashboard> createState() => _ManagerDashboardState();
}

class _ManagerDashboardState extends State<ManagerDashboard> {
  List<Employee> _employees = [];
  final Map<String, bool> _isActiveCache = {};
  final Map<String, String> _lastHeartbeatCache = {};
  bool _isLoading = false;
  String _searchQuery = '';
  String _selectedRoleFilter = 'All';
  int _sortColumnIndex = 0;
  bool _sortAscending = true;

  final Map<String, LiveStreamSession> _activeSessions = {};
  bool _isRequestSending = false;

  // ===== Caches from verify_employee =====
  final Map<String, String> _pcNumberCache = {};
  final Map<String, String> _pcTypeCache = {};
  final Map<String, bool> _onlineStatusCache = {};
  final Map<String, String> _deviceIdCache = {};
  final Map<String, String> _computerNameCache = {};
  final Map<String, String> _lastSeenCache = {};

  final List<String> _allowedPlayRoles = [
    'website developer',
    'data scrapper',
    'seo executive',
    'social media executive',
    'video editor',
    'graphics designer',
  ];

  Timer? _autoRefreshTimer;

  bool _permissionsGranted = false;
  static const String _managerPermKey = 'manager_perm_granted_v1';

  bool _shouldShowPlayButton(String role) {
    return _allowedPlayRoles.contains(role.trim().toLowerCase());
  }

  @override
  void initState() {
    super.initState();
    _initDesktopPlugins();          // ⭐ SAFE plugin init
    _checkAndRequestManagerPermissions();
    _fetchEmployees();

    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (mounted && _employees.isNotEmpty) {
        _verifyAllEmployees();
      }
    });
  }

  // ⭐ Initialize desktop plugins safely (no crash if DLL missing)
  Future<void> _initDesktopPlugins() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    try {
      await wm.windowManager.ensureInitialized();
      await wm.windowManager.setPreventClose(false);
      debugPrint('✅ window_manager initialized');
    } catch (e) {
      debugPrint('⚠️ window_manager not available: $e');
    }
    try {
      // Touch screen_retriever so the plugin loads
      await sr.screenRetriever.getPrimaryDisplay();
      debugPrint('✅ screen_retriever initialized');
    } catch (e) {
      debugPrint('⚠️ screen_retriever not available: $e');
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    for (final session in _activeSessions.values) {
      session.dispose();
    }
    super.dispose();
  }

  // ==================== PERMISSION HANDLING ====================
  Future<void> _checkAndRequestManagerPermissions() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyGranted = prefs.getBool(_managerPermKey) ?? false;

    if (alreadyGranted) {
      setState(() => _permissionsGranted = true);
      return;
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.amber.withOpacity(0.15),
              ),
              child: const Icon(Icons.security, color: Colors.amber, size: 24),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('One-Time Setup',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Manager Dashboard needs permissions to view live screens and playback recordings. This is a ONE-TIME setup.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _permBullet('View live employee screens'),
            _permBullet('Access screen recording history'),
            _permBullet('Play/Stop recording remotely'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await prefs.setBool(_managerPermKey, true);
              setState(() => _permissionsGranted = false);
            },
            child: const Text('Skip', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE94560),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await _runManagerPermissionSetup();
            },
            icon: const Icon(Icons.check, color: Colors.white, size: 20),
            label: const Text('Grant Permission',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _permBullet(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.greenAccent, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.85), fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _runManagerPermissionSetup() async {
    bool allOk = true;
    final List<String> results = [];

    try {
      if (!Platform.isWindows) {
        try {
          final storage = await Permission.storage.request();
          final photos = await Permission.photos.request();
          results.add('Storage: ${storage.isGranted ? "✅" : "❌"}');
          results.add('Photos: ${photos.isGranted ? "✅" : "❌"}');
        } catch (e) {
          results.add('Storage: Platform-managed');
        }
      } else {
        results.add('Storage: ✅ Windows managed');
      }

      try {
        final testResponse = await http
            .get(Uri.parse(baseUrl))
            .timeout(const Duration(seconds: 10));
        if (testResponse.statusCode == 200) {
          results.add('Server connection: ✅ OK');
        } else {
          results.add('Server connection: ⚠️ Status ${testResponse.statusCode}');
        }
      } catch (e) {
        results.add('Server connection: ❌ $e');
        allOk = false;
      }

      // ⭐ Verify screen_retriever plugin works (solves DLL issues at runtime)
      try {
        final disp = await sr.screenRetriever.getPrimaryDisplay();
        results.add('Screen retriever: ✅ ${disp.size.width.toInt()}x${disp.size.height.toInt()}');
      } catch (e) {
        results.add('Screen retriever: ⚠️ $e');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_managerPermKey, true);
      setState(() => _permissionsGranted = true);

      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF16213E),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Icon(
                  allOk ? Icons.check_circle : Icons.warning_amber,
                  color: allOk ? Colors.greenAccent : Colors.amber,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    allOk ? 'Setup Complete' : 'Setup Completed with Warnings',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: results
                  .map((r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(r,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
              ))
                  .toList(),
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE94560),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('Manager permission setup error: $e');
    }
  }

  // ==================== EMPLOYEE FETCH ====================
  Future<void> _fetchEmployees() async {
    if (mounted) setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse(baseUrl),
        headers: {'Accept': 'application/json'},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          final List list = data['data'] ?? [];
          if (mounted) {
            setState(() {
              _employees = list.map((e) => Employee.fromJson(e)).toList();
            });
          }
          _verifyAllEmployees();
        }
      } else {
        _showSnackBar('Failed to load employees', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error connecting to server: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyAllEmployees() async {
    const batchSize = 5;
    for (int i = 0; i < _employees.length; i += batchSize) {
      final end = (i + batchSize < _employees.length)
          ? i + batchSize
          : _employees.length;
      final batch = _employees.sublist(i, end);
      await Future.wait(batch.map((emp) => _verifyEmployee(emp.empId)));
    }
  }

  Future<void> _verifyEmployee(String empId) async {
    try {
      final response = await http.get(
        Uri.parse('$liveStreamUrl?action=verify_employee&emp_id=$empId'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success' && data['employee'] != null) {
          final emp = data['employee'];

          String safeStr(dynamic v, [String fallback = 'N/A']) {
            if (v == null) return fallback;
            final s = v.toString().trim();
            if (s.isEmpty || s.toLowerCase() == 'null') return fallback;
            return s;
          }

          if (mounted) {
            setState(() {
              final rawPcNumber = safeStr(emp['pc_number'], 'Personal PC');
              final rawPcType =
              safeStr(emp['pc_type'], 'personal').toLowerCase();

              _pcTypeCache[empId] = rawPcType;
              _pcNumberCache[empId] = rawPcNumber;

              _onlineStatusCache[empId] = data['is_online'] == true;
              _isActiveCache[empId] = data['is_active'] == true;
              _lastHeartbeatCache[empId] = safeStr(emp['last_heartbeat'], '');

              _deviceIdCache[empId] = safeStr(emp['device_id'], 'N/A');

              final devName = safeStr(emp['device_name'], '');
              final compName = safeStr(emp['computer_name'], '');
              _computerNameCache[empId] =
              devName.isNotEmpty && devName != 'N/A'
                  ? devName
                  : (compName.isNotEmpty && compName != 'N/A'
                  ? compName
                  : 'N/A');

              _lastSeenCache[empId] = safeStr(emp['last_seen'], '');
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _onlineStatusCache[empId] = false;
              _isActiveCache[empId] = false;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Verify employee error for $empId: $e');
    }
  }

  Future<String> _fetchNextEmpId() async {
    try {
      final uri = Uri.parse('$baseUrl?action=get_emp_id');
      final response =
      await http.get(uri, headers: {'Accept': 'application/json'});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success' && data['next_emp_id'] != null) {
          return data['next_emp_id'];
        }
      }
    } catch (e) {
      debugPrint('Error fetching EMP ID: $e');
    }
    return 'GS-E-01';
  }

  // ==================== AUTO PASSWORD API ====================
  Future<String?> _fetchAutoPassword(String empName, String role) async {
    try {
      final response = await http.post(
        Uri.parse(autoPasswordUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: json.encode({
          'name': empName.trim(),
          'role': role.trim(),
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success' && data['auto_password'] != null) {
          return data['auto_password'].toString();
        } else {
          _showSnackBar(
            data['message'] ?? 'Failed to generate auto password',
            isError: true,
          );
          return null;
        }
      } else {
        _showSnackBar('Server error: ${response.statusCode}', isError: true);
        return null;
      }
    } catch (e) {
      _showSnackBar('Error generating password: $e', isError: true);
      return null;
    }
  }

  String _generateLocalAutoPassword(String empName, String role) {
    String cleanName = empName
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
        .toLowerCase();

    if (cleanName.isEmpty) cleanName = 'employee';
    if (cleanName.length > 8) cleanName = cleanName.substring(0, 8);

    int existingCount = _employees
        .where((e) =>
    e.role == role &&
        e.managerName.toLowerCase().contains(cleanName))
        .length;

    int counter = existingCount + 1;
    return 'GS-$cleanName:@${counter.toString().padLeft(2, '0')}';
  }

  Future<bool> _createEmployee(Employee emp) async {
    try {
      final response = await http.post(
        Uri.parse(baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(emp.toCreateJson()),
      );
      final data = json.decode(response.body);
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          data['status'] == 'success') {
        _showSnackBar(data['message'] ?? 'Employee created successfully');
        _fetchEmployees();
        return true;
      } else {
        _showSnackBar(data['message'] ?? 'Failed to create employee',
            isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
    return false;
  }

  Future<bool> _updateEmployee(Employee emp) async {
    try {
      final response = await http.put(
        Uri.parse(baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(emp.toUpdateJson()),
      );
      final data = json.decode(response.body);
      if (response.statusCode == 200 && data['status'] == 'success') {
        _showSnackBar(data['message'] ?? 'Employee updated successfully');
        _fetchEmployees();
        return true;
      } else {
        _showSnackBar(data['message'] ?? 'Failed to update employee',
            isError: true);
      }
    } catch (e) {
      _showSnackBar('Error: $e', isError: true);
    }
    return false;
  }

  Future<void> _deleteEmployee(int dbId) async {
    try {
      final response = await http.delete(
        Uri.parse(baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'id': dbId}),
      );
      final data = json.decode(response.body);
      if (response.statusCode == 200 && data['status'] == 'success') {
        _showSnackBar(data['message'] ?? 'Employee deleted successfully');
        _fetchEmployees();
      } else {
        _showSnackBar(data['message'] ?? 'Failed to delete employee',
            isError: true);
      }
    } catch (e) {
      _showSnackBar('Error deleting employee: $e', isError: true);
    }
  }

  // ==================== START/STOP LIVE ====================
  Future<void> _sendLiveRequest(Employee emp) async {
    if (_isRequestSending) return;

    if (_activeSessions.containsKey(emp.empId)) {
      _showSnackBar('Already viewing ${emp.managerName}\'s screen');
      return;
    }

    setState(() => _isRequestSending = true);

    try {
      final response = await http.post(
        Uri.parse('$liveStreamUrl?action=send_live_request'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'emp_id': emp.empId}),
      );

      final data = json.decode(response.body);

      if (response.statusCode == 200 && data['status'] == 'success') {
        _showSnackBar('✅ Live request sent to ${emp.managerName}');

        final pcNumber =
            data['pc_number'] ?? _pcNumberCache[emp.empId] ?? 'Personal PC';
        final pcType =
            data['pc_type'] ?? _pcTypeCache[emp.empId] ?? 'personal';

        final session = LiveStreamSession(
          empId: emp.empId,
          empName: emp.managerName,
          pcNumber: pcNumber,
          pcType: pcType,
        );

        setState(() {
          _activeSessions[emp.empId] = session;
        });

        session.startPolling();
      } else {
        _showSnackBar(data['message'] ?? 'Failed to send request',
            isError: true);
      }
    } catch (e) {
      _showSnackBar('Error sending request: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isRequestSending = false);
    }
  }

  Future<void> _stopLiveForEmployee(String empId) async {
    final session = _activeSessions[empId];
    if (session == null) return;

    await session.stopAndClose();

    if (mounted) {
      setState(() {
        _activeSessions.remove(empId);
      });
      _showSnackBar('Recording stopped for $empId');
    }
  }

  void _showSnackBar(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  List<Employee> get _filteredEmployees {
    List<Employee> filtered = _employees.where((emp) {
      final matchesSearch = _searchQuery.isEmpty ||
          emp.managerName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          emp.email.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          emp.empId.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          emp.role.toLowerCase().contains(_searchQuery.toLowerCase());
      final matchesRole =
          _selectedRoleFilter == 'All' || emp.role == _selectedRoleFilter;
      return matchesSearch && matchesRole;
    }).toList();

    filtered.sort((a, b) {
      int result;
      switch (_sortColumnIndex) {
        case 0:
          result = a.empId.compareTo(b.empId);
          break;
        case 1:
          result = a.managerName.compareTo(b.managerName);
          break;
        case 2:
          result = (_pcNumberCache[a.empId] ?? a.pcNumber)
              .compareTo(_pcNumberCache[b.empId] ?? b.pcNumber);
          break;
        default:
          result = 0;
      }
      return _sortAscending ? result : -result;
    });

    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 900;

    return Scaffold(
      body: Stack(
        children: [
          Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF1A1A2E),
                  Color(0xFF16213E),
                  Color(0xFF0F3460)
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _buildAppBar(isDesktop),
                  _buildSearchAndFilterBar(isDesktop),
                  Expanded(
                    child: _isLoading
                        ? const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFFE94560)))
                        : _filteredEmployees.isEmpty
                        ? _buildEmptyState()
                        : isDesktop
                        ? _buildDesktopTable()
                        : _buildMobileListView(),
                  ),
                ],
              ),
            ),
          ),
          ..._buildFloatingViewers(screenWidth),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showEmployeeForm(),
        backgroundColor: const Color(0xFFE94560),
        icon: const Icon(Icons.add_rounded, color: Colors.white),
        label: const Text('Add Employee',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline,
              size: 80, color: Colors.white.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(
            'No employees found',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFloatingViewers(double screenWidth) {
    final List<Widget> viewers = [];
    final expandedSessions =
    _activeSessions.values.where((s) => !s.isMinimized).toList();

    final viewerWidth = screenWidth > 1400
        ? 560.0
        : screenWidth > 1100
        ? 480.0
        : screenWidth > 900
        ? 420.0
        : screenWidth * 0.9;
    final viewerHeight = viewerWidth * 0.85;

    int index = 0;
    for (final session in expandedSessions) {
      final offset = (index * 40).toDouble();
      viewers.add(
        Positioned(
          top: 80 + offset,
          right: 20 + offset,
          child: LiveStreamViewerWidget(
            session: session,
            width: viewerWidth,
            height: viewerHeight,
            onClose: () {
              setState(() {
                _activeSessions.remove(session.empId);
              });
            },
          ),
        ),
      );
      index++;
    }

    final minimized =
    _activeSessions.values.where((s) => s.isMinimized).toList();
    if (minimized.isNotEmpty) {
      viewers.add(
        Positioned(
          bottom: 20,
          right: 20,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: minimized.map((s) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: LiveStreamViewerWidget(
                  session: s,
                  width: viewerWidth,
                  height: viewerHeight,
                  onClose: () {
                    setState(() {
                      _activeSessions.remove(s.empId);
                    });
                  },
                ),
              );
            }).toList(),
          ),
        ),
      );
    }

    return viewers;
  }

  Widget _buildAppBar(bool isDesktop) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
      child: Row(
        children: [
          if (!isDesktop)
            const Icon(Icons.dashboard, color: Colors.white, size: 24)
          else
            const Text(
              'Manager Dashboard',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
          if (_activeSessions.isNotEmpty) ...[
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.greenAccent.withOpacity(0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.videocam,
                      color: Colors.greenAccent, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    '${_activeSessions.length} LIVE',
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            onPressed: _fetchEmployees,
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            tooltip: 'Refresh',
          ),
          IconButton(
            onPressed: _handleLogout,
            icon: const Icon(Icons.logout_outlined, color: Colors.white),
            tooltip: 'Logout',
          ),
        ],
      ),
    );
  }

  String _formatHeartbeat(String dt) {
    if (dt.isEmpty) return 'N/A';
    try {
      final parsed = DateTime.parse(dt.replaceFirst(' ', 'T'));
      final diff = DateTime.now().difference(parsed);

      if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      return '${diff.inDays}d ago';
    } catch (e) {
      return 'N/A';
    }
  }

  Future<void> _handleLogout() async {
    for (final session in _activeSessions.values) {
      await session.stopAndClose();
    }
    _activeSessions.clear();

    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (context) => const LogIn()));
    }
  }

  Widget _buildSearchAndFilterBar(bool isDesktop) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search Employee, PC NO, ID...',
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
          prefixIcon: const Icon(Icons.search, color: Colors.white),
          filled: true,
          fillColor: Colors.white.withOpacity(0.08),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _getStatusInfo(String empId) {
    final isActive = _isActiveCache[empId] ?? false;
    final isStreaming = _activeSessions.containsKey(empId);
    final lastHeartbeat = _lastHeartbeatCache[empId] ?? '';

    if (isStreaming) {
      return {
        'color': Colors.redAccent,
        'text': 'Recording',
        'subtext': 'Live now',
        'showPulse': true,
      };
    } else if (isActive) {
      return {
        'color': Colors.greenAccent,
        'text': 'Active',
        'subtext': 'App running',
        'showPulse': false,
      };
    } else {
      return {
        'color': Colors.grey,
        'text': 'Inactive',
        'subtext': lastHeartbeat.isNotEmpty
            ? 'Last: ${_formatHeartbeat(lastHeartbeat)}'
            : 'Never',
        'showPulse': false,
      };
    }
  }

  Widget _buildPcChip(String empId) {
    final pcNumber = _pcNumberCache[empId] ?? 'Personal PC';
    final pcType = _pcTypeCache[empId] ?? 'personal';
    final isOfficePc = pcType == 'office';

    final label = (pcNumber.isEmpty ||
        pcNumber.toLowerCase() == 'null' ||
        pcNumber == 'N/A')
        ? 'Personal PC'
        : pcNumber;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isOfficePc
            ? Colors.green.withOpacity(0.2)
            : Colors.blueGrey.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isOfficePc ? Colors.green : Colors.blueGrey,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isOfficePc ? Icons.computer : Icons.laptop_mac,
            size: 14,
            color: isOfficePc ? Colors.greenAccent : Colors.lightBlueAccent,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: isOfficePc ? Colors.greenAccent : Colors.lightBlueAccent,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopTable() {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.of(context).size.width - 32,
          ),
          child: DataTable(
            columns: const [
              DataColumn(
                  label:
                  Text('EMP ID', style: TextStyle(color: Colors.white))),
              DataColumn(
                  label: Text('NAME', style: TextStyle(color: Colors.white))),
              DataColumn(
                  label: Text('DEVICE / PC',
                      style: TextStyle(color: Colors.white))),
              DataColumn(
                  label: Text('ROLE', style: TextStyle(color: Colors.white))),
              DataColumn(
                  label:
                  Text('STATUS', style: TextStyle(color: Colors.white))),
              DataColumn(
                  label:
                  Text('ACTIONS', style: TextStyle(color: Colors.white))),
            ],
            rows: _filteredEmployees.map((emp) {
              final showPlay = _shouldShowPlayButton(emp.role);
              final isStreaming = _activeSessions.containsKey(emp.empId);
              final status = _getStatusInfo(emp.empId);

              return DataRow(cells: [
                DataCell(Text(emp.empId,
                    style: const TextStyle(color: Colors.white))),
                DataCell(Text(emp.managerName,
                    style: const TextStyle(color: Colors.white))),
                DataCell(_buildPcChip(emp.empId)),
                DataCell(Text(emp.role,
                    style: const TextStyle(color: Colors.white))),
                DataCell(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: status['color'] as Color,
                          boxShadow: (status['showPulse'] as bool)
                              ? [
                            BoxShadow(
                              color: (status['color'] as Color)
                                  .withOpacity(0.6),
                              blurRadius: 8,
                              spreadRadius: 2,
                            ),
                          ]
                              : (status['text'] == 'Active'
                              ? [
                            BoxShadow(
                              color: Colors.greenAccent
                                  .withOpacity(0.5),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ]
                              : <BoxShadow>[]),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            status['text'] as String,
                            style: TextStyle(
                              color: status['color'] as Color,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            status['subtext'] as String,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                DataCell(
                  Row(
                    children: [
                      if (showPlay) ...[
                        if (!isStreaming)
                          IconButton(
                            onPressed: _isRequestSending
                                ? null
                                : () => _sendLiveRequest(emp),
                            icon: Icon(
                              Icons.play_circle_fill,
                              color: _isRequestSending
                                  ? Colors.white38
                                  : Colors.greenAccent,
                            ),
                            tooltip: 'Start Live View',
                          )
                        else
                          IconButton(
                            onPressed: () => _stopLiveForEmployee(emp.empId),
                            icon: const Icon(
                              Icons.stop_circle,
                              color: Colors.redAccent,
                            ),
                            tooltip: 'Stop Recording',
                          ),
                      ],
                      IconButton(
                        icon: const Icon(Icons.history,
                            color: Colors.lightBlueAccent),
                        onPressed: () => _showHistoryDialog(emp),
                        tooltip: 'View Video History',
                      ),
                      IconButton(
                        icon: const Icon(Icons.info_outline,
                            color: Colors.lightGreenAccent),
                        onPressed: () => _showEmployeeInfo(emp),
                        tooltip: 'Device Info',
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.amber),
                        onPressed: () => _showEmployeeForm(employee: emp),
                        tooltip: 'Edit',
                      ),
                      IconButton(
                        icon:
                        const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () => _deleteEmployee(emp.id),
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                ),
              ]);
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileListView() {
    return ListView.builder(
      itemCount: _filteredEmployees.length,
      itemBuilder: (context, index) {
        final emp = _filteredEmployees[index];
        final showPlay = _shouldShowPlayButton(emp.role);
        final isStreaming = _activeSessions.containsKey(emp.empId);
        final status = _getStatusInfo(emp.empId);
        final pcNumber = _pcNumberCache[emp.empId] ?? 'Loading...';

        return Card(
          color: Colors.white.withOpacity(0.06),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: (status['color'] as Color).withOpacity(0.2),
              child: Text(
                emp.managerName.isNotEmpty
                    ? emp.managerName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: status['color'] as Color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(
              emp.managerName,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${emp.empId} | ${emp.role}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: status['color'] as Color,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      status['text'] as String,
                      style: TextStyle(
                        color: status['color'] as Color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        pcNumber,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showPlay) ...[
                  if (!isStreaming)
                    IconButton(
                      onPressed: _isRequestSending
                          ? null
                          : () => _sendLiveRequest(emp),
                      icon: Icon(
                        Icons.play_circle_outline,
                        color: _isRequestSending
                            ? Colors.white38
                            : Colors.greenAccent,
                      ),
                    )
                  else
                    IconButton(
                      onPressed: () => _stopLiveForEmployee(emp.empId),
                      icon: const Icon(Icons.stop_circle_outlined,
                          color: Colors.redAccent),
                    ),
                ],
                PopupMenuButton<String>(
                  color: const Color(0xFF16213E),
                  icon: const Icon(Icons.more_vert, color: Colors.white70),
                  onSelected: (value) {
                    switch (value) {
                      case 'history':
                        _showHistoryDialog(emp);
                        break;
                      case 'info':
                        _showEmployeeInfo(emp);
                        break;
                      case 'edit':
                        _showEmployeeForm(employee: emp);
                        break;
                      case 'delete':
                        _deleteEmployee(emp.id);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'history',
                      child: Row(
                        children: [
                          Icon(Icons.history,
                              color: Colors.lightBlueAccent, size: 18),
                          SizedBox(width: 8),
                          Text('Video History',
                              style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'info',
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              color: Colors.lightGreenAccent, size: 18),
                          SizedBox(width: 8),
                          Text('Device Info',
                              style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit, color: Colors.amber, size: 18),
                          SizedBox(width: 8),
                          Text('Edit', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: Colors.redAccent, size: 18),
                          SizedBox(width: 8),
                          Text('Delete', style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEmployeeInfo(Employee emp) {
    final pcNumber = _pcNumberCache[emp.empId] ?? 'Personal PC';
    final pcType = _pcTypeCache[emp.empId] ?? 'personal';
    final deviceId = _deviceIdCache[emp.empId] ?? 'N/A';
    final computerName = _computerNameCache[emp.empId] ?? 'N/A';
    final lastSeen = _lastSeenCache[emp.empId] ?? 'N/A';
    final status = _getStatusInfo(emp.empId);

    final pcDisplay = (pcNumber.isEmpty ||
        pcNumber.toLowerCase() == 'null' ||
        pcNumber == 'N/A')
        ? 'Personal PC'
        : pcNumber;

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: const Color(0xFF16213E),
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 440,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.lightGreenAccent.withOpacity(0.15),
                      ),
                      child: const Icon(Icons.computer,
                          color: Colors.lightGreenAccent, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            emp.managerName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            '${emp.empId} • ${emp.role}',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _infoRow(
                  'App Status',
                  status['text'] as String,
                  status['color'] as Color,
                ),
                _infoRow(
                  'Last Heartbeat',
                  _lastHeartbeatCache[emp.empId]?.isNotEmpty == true
                      ? _formatHeartbeat(_lastHeartbeatCache[emp.empId]!)
                      : 'Never',
                  Colors.white70,
                ),
                _infoRow(
                    'Device Type',
                    pcType == 'office' ? 'Office PC' : 'Personal PC',
                    pcType == 'office'
                        ? Colors.greenAccent
                        : Colors.lightBlueAccent),
                _infoRow('PC Number', pcDisplay, Colors.white),
                _infoRow('Device ID', deviceId, Colors.white70),
                _infoRow('Computer Name', computerName, Colors.white70),
                _infoRow(
                    'Last Seen', _formatDateTime(lastSeen), Colors.white70),
                _infoRow('Email', emp.email, Colors.white70),
                _infoRow('Mobile', emp.mobile, Colors.white70),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _infoRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(String? dt) {
    if (dt == null || dt.isEmpty || dt == 'N/A') return 'N/A';
    try {
      final parsed = DateTime.parse(dt.replaceFirst(' ', 'T'));
      return '${parsed.day}/${parsed.month}/${parsed.year} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return dt;
    }
  }

  Future<void> _showHistoryDialog(Employee emp) async {
    final pcNumber = _pcNumberCache[emp.empId] ?? 'Personal PC';
    final pcType = _pcTypeCache[emp.empId] ?? 'personal';

    showDialog(
      context: context,
      builder: (context) {
        return _HistoryDialog(
          empId: emp.empId,
          empName: emp.managerName,
          pcNumber: (pcNumber.isEmpty ||
              pcNumber.toLowerCase() == 'null' ||
              pcNumber == 'N/A')
              ? 'Personal PC'
              : pcNumber,
          pcType: pcType,
          deviceId: _deviceIdCache[emp.empId] ?? 'N/A',
          computerName: _computerNameCache[emp.empId] ?? 'N/A',
        );
      },
    );
  }

  // ==================== EMPLOYEE FORM WITH AUTO PASSWORD ====================
  void _showEmployeeForm({Employee? employee}) async {
    final formKey = GlobalKey<FormState>();
    final isEditing = employee != null;

    final nameController =
    TextEditingController(text: employee?.managerName ?? '');
    final emailController = TextEditingController(text: employee?.email ?? '');
    final mobileController =
    TextEditingController(text: employee?.mobile ?? '');
    final passwordController = TextEditingController();

    String empId = employee?.empId ?? '';
    String selectedRole = employee?.role ?? availableRoleChoices.first;
    bool isSubmitting = false;
    bool isGeneratingPwd = false;

    if (!isEditing) {
      empId = await _fetchNextEmpId();
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final canGeneratePwd = nameController.text.trim().length >= 3 &&
                selectedRole.isNotEmpty;

            return AlertDialog(
              backgroundColor: const Color(0xFF16213E),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: Text(
                isEditing ? 'Edit Employee' : 'Add New Employee',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        initialValue: empId,
                        readOnly: true,
                        style: const TextStyle(color: Colors.white70),
                        decoration: const InputDecoration(
                          labelText: 'Employee ID (auto)',
                          labelStyle: TextStyle(color: Colors.white60),
                          prefixIcon: Icon(Icons.badge,
                              color: Colors.lightBlueAccent, size: 20),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: nameController,
                              style: const TextStyle(color: Colors.white),
                              onChanged: (_) => setDialogState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'Full Name',
                                labelStyle: TextStyle(color: Colors.white60),
                                prefixIcon: Icon(Icons.person,
                                    color: Colors.white54, size: 20),
                              ),
                              validator: (val) =>
                              val == null || val.trim().isEmpty
                                  ? 'Enter full name'
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Tooltip(
                            message: canGeneratePwd
                                ? 'Generate auto password (GS-name:@01)'
                                : 'Enter name & role first',
                            child: Container(
                              height: 48,
                              width: 48,
                              margin: const EdgeInsets.only(top: 8),
                              decoration: BoxDecoration(
                                color: canGeneratePwd
                                    ? const Color(0xFFE94560)
                                    : Colors.white12,
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: canGeneratePwd
                                    ? [
                                  BoxShadow(
                                    color: const Color(0xFFE94560)
                                        .withOpacity(0.4),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ]
                                    : [],
                              ),
                              child: IconButton(
                                icon: isGeneratingPwd
                                    ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white),
                                )
                                    : const Icon(Icons.add,
                                    color: Colors.white, size: 24),
                                onPressed:
                                (!canGeneratePwd || isGeneratingPwd)
                                    ? null
                                    : () async {
                                  setDialogState(
                                          () => isGeneratingPwd = true);

                                  String? pwd =
                                  await _fetchAutoPassword(
                                    nameController.text.trim(),
                                    selectedRole,
                                  );

                                  pwd ??=
                                      _generateLocalAutoPassword(
                                        nameController.text.trim(),
                                        selectedRole,
                                      );

                                  passwordController.text = pwd;

                                  if (mounted) {
                                    setDialogState(() {
                                      isGeneratingPwd = false;
                                    });
                                    _showSnackBar(
                                        '🔑 Auto password generated: $pwd');
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: emailController,
                        style: const TextStyle(color: Colors.white),
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email Address',
                          labelStyle: TextStyle(color: Colors.white60),
                          prefixIcon: Icon(Icons.email,
                              color: Colors.white54, size: 20),
                        ),
                        validator: (val) =>
                        val == null || !val.contains('@')
                            ? 'Enter a valid email'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: mobileController,
                        style: const TextStyle(color: Colors.white),
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Mobile Number',
                          labelStyle: TextStyle(color: Colors.white60),
                          prefixIcon: Icon(Icons.phone,
                              color: Colors.white54, size: 20),
                        ),
                        validator: (val) =>
                        val == null || val.trim().length < 10
                            ? 'Enter valid mobile number'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: availableRoleChoices
                                  .contains(selectedRole)
                                  ? selectedRole
                                  : availableRoleChoices.first,
                              dropdownColor: const Color(0xFF16213E),
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'Role',
                                labelStyle:
                                TextStyle(color: Colors.white60),
                                prefixIcon: Icon(Icons.work,
                                    color: Colors.white54, size: 20),
                              ),
                              items: availableRoleChoices.map((role) {
                                return DropdownMenuItem(
                                  value: role,
                                  child: Text(role),
                                );
                              }).toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  setDialogState(
                                          () => selectedRole = value);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 6),
                          Tooltip(
                            message: canGeneratePwd
                                ? 'Generate auto password'
                                : 'Enter name & role first',
                            child: Container(
                              height: 48,
                              width: 48,
                              margin: const EdgeInsets.only(top: 8),
                              decoration: BoxDecoration(
                                color: canGeneratePwd
                                    ? const Color(0xFFE94560)
                                    : Colors.white12,
                                borderRadius: BorderRadius.circular(10),
                                boxShadow: canGeneratePwd
                                    ? [
                                  BoxShadow(
                                    color: const Color(0xFFE94560)
                                        .withOpacity(0.4),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ]
                                    : [],
                              ),
                              child: IconButton(
                                icon: isGeneratingPwd
                                    ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white),
                                )
                                    : const Icon(Icons.add,
                                    color: Colors.white, size: 24),
                                onPressed:
                                (!canGeneratePwd || isGeneratingPwd)
                                    ? null
                                    : () async {
                                  setDialogState(
                                          () => isGeneratingPwd = true);

                                  String? pwd =
                                  await _fetchAutoPassword(
                                    nameController.text.trim(),
                                    selectedRole,
                                  );
                                  pwd ??=
                                      _generateLocalAutoPassword(
                                        nameController.text.trim(),
                                        selectedRole,
                                      );

                                  passwordController.text = pwd;

                                  if (mounted) {
                                    setDialogState(() {
                                      isGeneratingPwd = false;
                                    });
                                    _showSnackBar(
                                        '🔑 Auto password generated: $pwd');
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: passwordController,
                        readOnly: true,
                        obscureText: false,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1,
                        ),
                        decoration: InputDecoration(
                          labelText: isEditing
                              ? 'Password (optional)'
                              : 'Auto Password',
                          labelStyle: const TextStyle(color: Colors.white60),
                          prefixIcon: const Icon(Icons.lock,
                              color: Colors.greenAccent, size: 20),
                          suffixIcon: passwordController.text.isNotEmpty
                              ? IconButton(
                            icon: const Icon(Icons.copy,
                                color: Colors.greenAccent, size: 18),
                            tooltip: 'Copy password',
                            onPressed: () {
                              _showSnackBar(
                                  'Password: ${passwordController.text}');
                            },
                          )
                              : null,
                          helperText:
                          'Format: GS-{name}:@{01}  •  Tap + to generate',
                          helperStyle: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 10,
                          ),
                        ),
                        validator: (val) {
                          if (!isEditing &&
                              (val == null || val.trim().length < 6)) {
                            return 'Tap + to generate auto password';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                  isSubmitting ? null : () => Navigator.pop(context),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.white60)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE94560),
                  ),
                  onPressed: isSubmitting
                      ? null
                      : () async {
                    if (formKey.currentState!.validate()) {
                      setDialogState(() => isSubmitting = true);

                      final newEmp = Employee(
                        id: employee?.id ?? 0,
                        empId: empId,
                        managerName: nameController.text.trim(),
                        email: emailController.text.trim(),
                        mobile: mobileController.text.trim(),
                        role: selectedRole,
                        pcNumber: employee?.pcNumber ?? 'N/A',
                        password: passwordController.text.trim(),
                      );

                      bool success;
                      if (isEditing) {
                        success = await _updateEmployee(newEmp);
                      } else {
                        success = await _createEmployee(newEmp);
                      }

                      if (mounted && success) {
                        Navigator.pop(context);
                      } else {
                        setDialogState(() => isSubmitting = false);
                      }
                    }
                  },
                  child: isSubmitting
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                      : Text(
                    isEditing ? 'Update' : 'Register',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ==================== LIVE STREAM SESSION ====================
class LiveStreamSession {
  final String empId;
  final String empName;
  final String pcNumber;
  final String pcType;

  Timer? _pollTimer;
  Uint8List? currentFrameBytes;
  int refreshCount = 0;
  String status = 'waiting';
  DateTime? lastFrameTime;
  DateTime? capturedAt;
  String? windowTitle;
  bool isPolling = false;
  bool isMinimized = false;
  bool isDisposed = false;
  int lastFrameCounter = -1;

  LiveStreamSession({
    required this.empId,
    required this.empName,
    required this.pcNumber,
    required this.pcType,
  });

  void startPolling() {
    if (isPolling) return;
    isPolling = true;

    _pollTimer?.cancel();
    _fetchFrame();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      if (!isDisposed) {
        _fetchFrame();
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _fetchFrame() async {
    if (isDisposed) return;

    try {
      final response = await http.get(
        Uri.parse('$liveStreamUrl?action=get_live_stream&emp_id=$empId'
            '&_ts=${DateTime.now().millisecondsSinceEpoch}'),
        headers: {
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && !isDisposed) {
        final data = json.decode(response.body);
        final s = data['status'];

        if (s == 'success' && data['image_base64'] != null) {
          final newFrameB64 = data['image_base64'] as String;
          final serverFrameCounter = data['frame_counter'] ?? 0;

          if (serverFrameCounter != lastFrameCounter) {
            final decodedBytes = await compute(_decodeBase64Task, newFrameB64);

            if (!isDisposed && decodedBytes.isNotEmpty) {
              currentFrameBytes = decodedBytes;
              lastFrameCounter = serverFrameCounter;
              refreshCount++;
              status = 'live';
              lastFrameTime = DateTime.now();
              windowTitle = data['window_title'];
              if (data['captured_at'] != null) {
                try {
                  capturedAt = DateTime.parse(
                      data['captured_at'].replaceFirst(' ', 'T'));
                } catch (_) {}
              }
            }
          }
        } else if (s == 'stale') {
          status = 'stale';
        } else if (s == 'waiting') {
          status = 'waiting';
        }
      }
    } catch (e) {
      debugPrint('Error fetching live frame for $empId: $e');
    }
  }

  Future<void> stopAndClose() async {
    isDisposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;

    try {
      await http.post(
        Uri.parse('$liveStreamUrl?action=stop_live_stream'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'emp_id': empId, 'keep_history': true}),
      );
    } catch (e) {
      debugPrint('Error stopping stream: $e');
    }
  }

  void dispose() {
    isDisposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}

// ==================== FLOATING LIVE STREAM VIEWER ====================
class LiveStreamViewerWidget extends StatefulWidget {
  final LiveStreamSession session;
  final VoidCallback onClose;
  final double width;
  final double height;

  const LiveStreamViewerWidget({
    super.key,
    required this.session,
    required this.onClose,
    required this.width,
    required this.height,
  });

  @override
  State<LiveStreamViewerWidget> createState() => _LiveStreamViewerWidgetState();
}

class _LiveStreamViewerWidgetState extends State<LiveStreamViewerWidget> {
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return session.isMinimized ? _buildMinimized() : _buildExpanded();
  }

  Widget _buildMinimized() {
    final session = widget.session;
    return GestureDetector(
      onDoubleTap: () {
        setState(() {
          session.isMinimized = false;
        });
      },
      child: Container(
        width: 220,
        height: 58,
        decoration: BoxDecoration(
          color: const Color(0xFF16213E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: session.status == 'live'
                ? Colors.greenAccent.withOpacity(0.5)
                : Colors.amber.withOpacity(0.5),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 10),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                session.status == 'live' ? Colors.greenAccent : Colors.amber,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    session.empName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    session.pcNumber,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.open_in_full,
                  color: Colors.white54, size: 16),
              onPressed: () {
                setState(() {
                  session.isMinimized = false;
                });
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white54, size: 18),
              onPressed: () async {
                await session.stopAndClose();
                widget.onClose();
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded() {
    final session = widget.session;
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: session.status == 'live'
              ? Colors.greenAccent.withOpacity(0.5)
              : session.status == 'stale'
              ? Colors.orange.withOpacity(0.5)
              : Colors.amber.withOpacity(0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10.0),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: session.status == 'live'
                        ? Colors.greenAccent
                        : session.status == 'stale'
                        ? Colors.orange
                        : Colors.amber,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.empName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          Text(
                            'ID: ${session.empId}',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 10,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: session.pcType == 'office'
                                  ? Colors.greenAccent.withOpacity(0.15)
                                  : Colors.lightBlueAccent.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              session.pcNumber,
                              style: TextStyle(
                                color: session.pcType == 'office'
                                    ? Colors.greenAccent
                                    : Colors.lightBlueAccent,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: session.status == 'live'
                        ? Colors.greenAccent.withOpacity(0.15)
                        : session.status == 'stale'
                        ? Colors.orange.withOpacity(0.15)
                        : Colors.amber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: session.status == 'live'
                          ? Colors.greenAccent.withOpacity(0.5)
                          : session.status == 'stale'
                          ? Colors.orange.withOpacity(0.5)
                          : Colors.amber.withOpacity(0.5),
                    ),
                  ),
                  child: Text(
                    session.status == 'live'
                        ? 'LIVE'
                        : session.status == 'stale'
                        ? 'STALE'
                        : 'WAITING',
                    style: TextStyle(
                      color: session.status == 'live'
                          ? Colors.greenAccent
                          : session.status == 'stale'
                          ? Colors.orange
                          : Colors.amber,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                IconButton(
                  icon: const Icon(Icons.history,
                      color: Colors.lightBlueAccent, size: 16),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => _HistoryDialog(
                        empId: session.empId,
                        empName: session.empName,
                        pcNumber: session.pcNumber,
                        pcType: session.pcType,
                        deviceId: 'N/A',
                        computerName: 'N/A',
                      ),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'View History',
                ),
                const SizedBox(width: 2),
                IconButton(
                  icon: const Icon(Icons.minimize,
                      color: Colors.white70, size: 16),
                  onPressed: () {
                    setState(() {
                      session.isMinimized = true;
                    });
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Minimize',
                ),
                const SizedBox(width: 2),
                IconButton(
                  icon: const Icon(Icons.stop_circle,
                      color: Colors.redAccent, size: 18),
                  onPressed: () async {
                    await session.stopAndClose();
                    widget.onClose();
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Stop Recording',
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: session.status == 'live'
                      ? Colors.greenAccent.withOpacity(0.3)
                      : Colors.white.withOpacity(0.1),
                ),
              ),
              child: session.currentFrameBytes == null
                  ? _buildWaitingView()
                  : _buildLiveView(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
            child: Row(
              children: [
                const Icon(Icons.screen_share,
                    color: Colors.greenAccent, size: 11),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    session.lastFrameTime != null
                        ? 'Updated: ${_formatTime(session.lastFrameTime!)}  •  Frames: ${session.refreshCount}'
                        : 'Waiting for first frame...',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 9,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              color: Colors.amber,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Waiting for ${widget.session.empName}...',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Employee must accept the request',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveView() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.black,
            child: Image.memory(
              widget.session.currentFrameBytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image_outlined,
                          size: 40, color: Colors.white.withOpacity(0.3)),
                      const SizedBox(height: 8),
                      Text('Invalid frame data',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 11)),
                    ],
                  ),
                );
              },
            ),
          ),
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Colors.white, size: 8),
                  SizedBox(width: 4),
                  Text('LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== VIDEO HISTORY DIALOG ====================
class _HistoryDialog extends StatefulWidget {
  final String empId;
  final String empName;
  final String pcNumber;
  final String pcType;
  final String deviceId;
  final String computerName;

  const _HistoryDialog({
    required this.empId,
    required this.empName,
    required this.pcNumber,
    required this.pcType,
    required this.deviceId,
    required this.computerName,
  });

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  List<Map<String, dynamic>> _videoList = [];

  bool _isLoading = true;
  String? _error;

  int _selectedVideoIndex = -1;
  List<Map<String, dynamic>> _selectedVideoFrames = [];
  List<Uint8List> _decodedFrames = [];

  bool _isPlaying = false;
  int _playbackIndex = 0;
  Timer? _playbackTimer;
  Timer? _autoRefreshTimer;
  double _playbackSpeed = 4.0;

  final ValueNotifier<int> _frameNotifier = ValueNotifier<int>(0);
  final Map<int, ui.Image> _uiImageCache = {};
  final Map<String, ui.Image> _thumbCache = {};

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _autoRefreshTimer?.cancel();
    _frameNotifier.dispose();
    for (final img in _uiImageCache.values) {
      try {
        img.dispose();
      } catch (_) {}
    }
    for (final img in _thumbCache.values) {
      try {
        img.dispose();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http
          .get(
        Uri.parse(
            '$liveStreamUrl?action=get_video_playback&emp_id=${widget.empId}&limit=500'),
        headers: {'Accept': 'application/json'},
      )
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      List<Map<String, dynamic>> allFrames = [];

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success' && data['frames'] != null) {
          allFrames = List<Map<String, dynamic>>.from(data['frames']);
        }
      }

      final videos = _groupFramesIntoVideos(allFrames);

      setState(() {
        _videoList = videos;
        _isLoading = false;
        if (allFrames.isEmpty) {
          _error = 'No recordings available yet';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error loading: $e';
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> _groupFramesIntoVideos(
      List<Map<String, dynamic>> frames) {
    if (frames.isEmpty) return [];

    final List<Map<String, dynamic>> videos = [];
    List<Map<String, dynamic>> currentSession = [];
    DateTime? lastTime;

    for (final frame in frames) {
      try {
        final frameTime = DateTime.parse(
            (frame['captured_at'] as String).replaceFirst(' ', 'T'));

        if (lastTime == null ||
            frameTime.difference(lastTime).inMinutes <= 5) {
          currentSession.add(frame);
        } else {
          if (currentSession.isNotEmpty) {
            videos.add(_buildVideoMetadata(currentSession));
            currentSession = [];
          }
          currentSession.add(frame);
        }
        lastTime = frameTime;
      } catch (e) {
        currentSession.add(frame);
      }
    }

    if (currentSession.isNotEmpty) {
      videos.add(_buildVideoMetadata(currentSession));
    }

    videos.sort((a, b) {
      final aStart = a['start_time'] as String? ?? '';
      final bStart = b['start_time'] as String? ?? '';
      return bStart.compareTo(aStart);
    });

    return videos;
  }

  Map<String, dynamic> _buildVideoMetadata(List<Map<String, dynamic>> frames) {
    return {
      'frames': List<Map<String, dynamic>>.from(frames),
      'frame_count': frames.length,
      'start_time': frames.first['captured_at'],
      'end_time': frames.last['captured_at'],
      'duration_minutes': frames.length,
      'first_thumbnail': frames.first['image_base64'],
    };
  }

  Future<ui.Image?> _decodeToUiImage(String b64) async {
    try {
      final bytes = base64Decode(b64);
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 1280,
      );
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      return null;
    }
  }

  Future<void> _predecodeFrames(List<Map<String, dynamic>> frames) async {
    for (final img in _uiImageCache.values) {
      try {
        img.dispose();
      } catch (_) {}
    }
    _uiImageCache.clear();

    const batchSize = 8;
    for (int i = 0; i < frames.length; i += batchSize) {
      final end =
      (i + batchSize < frames.length) ? i + batchSize : frames.length;

      final futures = <Future<void>>[];
      for (int j = i; j < end; j++) {
        final b64 = frames[j]['image_base64'] as String?;
        if (b64 == null || b64.isEmpty) continue;

        futures.add(
          _decodeToUiImage(b64).then((img) {
            if (img != null && mounted) {
              _uiImageCache[j] = img;
            }
          }),
        );
      }
      await Future.wait(futures);

      if (!mounted) return;

      if (_uiImageCache.isNotEmpty) {
        setState(() {});
      }

      await Future.delayed(const Duration(milliseconds: 2));
    }

    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openVideo(int videoIndex) async {
    final video = _videoList[videoIndex];
    final frames = List<Map<String, dynamic>>.from(video['frames'] as List);

    setState(() {
      _selectedVideoIndex = videoIndex;
      _selectedVideoFrames = frames;
      _decodedFrames = [];
      _playbackIndex = 0;
      _isPlaying = false;
    });
    _frameNotifier.value = 0;

    await _predecodeFrames(frames);
  }

  void _closeVideo() {
    _playbackTimer?.cancel();
    for (final img in _uiImageCache.values) {
      try {
        img.dispose();
      } catch (_) {}
    }
    _uiImageCache.clear();

    setState(() {
      _selectedVideoIndex = -1;
      _selectedVideoFrames = [];
      _decodedFrames = [];
      _isPlaying = false;
      _playbackIndex = 0;
    });
  }

  void _startPlayback() {
    if (_uiImageCache.isEmpty) return;

    setState(() {
      _isPlaying = true;
      _playbackIndex = 0;
      _frameNotifier.value = 0;
    });
    _scheduleNextFrame();
  }

  void _stopPlayback() {
    _playbackTimer?.cancel();
    _playbackTimer = null;
    setState(() {
      _isPlaying = false;
    });
  }

  void _scheduleNextFrame() {
    _playbackTimer?.cancel();

    final intervalMs = (200 / _playbackSpeed).round().clamp(30, 3000);

    _playbackTimer = Timer(Duration(milliseconds: intervalMs), () {
      if (!mounted || !_isPlaying) return;

      if (_playbackIndex < _selectedVideoFrames.length - 1) {
        _playbackIndex++;
        _frameNotifier.value = _playbackIndex;
        _scheduleNextFrame();
      } else {
        setState(() {
          _isPlaying = false;
        });
      }
    });
  }

  void _setPlaybackSpeed(double speed) {
    setState(() => _playbackSpeed = speed);
    if (_isPlaying) _scheduleNextFrame();
  }

  void _seekTo(int index) {
    if (index < 0 || index >= _selectedVideoFrames.length) return;
    setState(() => _playbackIndex = index);
    _frameNotifier.value = index;
    if (_isPlaying) _scheduleNextFrame();
  }

  void _skipBackward() {
    _seekTo((_playbackIndex - 10).clamp(0, _selectedVideoFrames.length - 1));
  }

  void _skipForward() {
    _seekTo((_playbackIndex + 10).clamp(0, _selectedVideoFrames.length - 1));
  }

  String _formatDateTime(String? dt) {
    if (dt == null || dt.isEmpty) return 'N/A';
    try {
      final parsed = DateTime.parse(dt.replaceFirst(' ', 'T'));
      return '${parsed.day.toString().padLeft(2, '0')}/${parsed.month.toString().padLeft(2, '0')} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return dt;
    }
  }

  String _formatTimeOnly(String? dt) {
    if (dt == null || dt.isEmpty) return '--:--';
    try {
      final parsed = DateTime.parse(dt.replaceFirst(' ', 'T'));
      return '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
    } catch (e) {
      return dt;
    }
  }

  String _formatDuration(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isWide = screenWidth > 700;

    return Dialog(
      backgroundColor: const Color(0xFF16213E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        width: isWide ? screenWidth * 0.9 : screenWidth * 0.95,
        height: MediaQuery.of(context).size.height * 0.92,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildHeader(isWide),
            const SizedBox(height: 12),
            _buildDeviceInfoBar(isWide),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? const Center(
                  child:
                  CircularProgressIndicator(color: Color(0xFFE94560)))
                  : _error != null
                  ? _buildErrorView()
                  : _selectedVideoIndex == -1
                  ? _buildVideoList(isWide)
                  : _buildVideoPlayer(isWide),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(bool isWide) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.lightBlueAccent.withOpacity(0.15),
          ),
          child: const Icon(Icons.video_library,
              color: Colors.lightBlueAccent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _selectedVideoIndex == -1
                    ? 'Screen Recordings'
                    : 'Video Playback',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              Text(
                _selectedVideoIndex == -1
                    ? '${widget.empName} • ${widget.empId} • ${_videoList.length} videos'
                    : '${widget.empName} • ${_selectedVideoFrames.length} frames • ${_uiImageCache.length} cached',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 11,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (_selectedVideoIndex != -1)
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white70),
            onPressed: _closeVideo,
            tooltip: 'Back to list',
          ),
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white70),
          onPressed: _loadHistory,
          tooltip: 'Refresh',
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () {
            _stopPlayback();
            Navigator.pop(context);
          },
        ),
      ],
    );
  }

  Widget _buildDeviceInfoBar(bool isWide) {
    final isOfficePc = widget.pcType == 'office';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isOfficePc
              ? Colors.greenAccent.withOpacity(0.3)
              : Colors.lightBlueAccent.withOpacity(0.3),
        ),
      ),
      child: isWide
          ? Row(
        children: [
          _deviceChip(
            isOfficePc ? Icons.computer : Icons.laptop_mac,
            widget.pcNumber,
            isOfficePc ? Colors.greenAccent : Colors.lightBlueAccent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Device: ${widget.deviceId}',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            'PC: ${widget.computerName}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 11,
            ),
          ),
        ],
      )
          : Row(
        children: [
          _deviceChip(
            isOfficePc ? Icons.computer : Icons.laptop_mac,
            widget.pcNumber,
            isOfficePc ? Colors.greenAccent : Colors.lightBlueAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.computerName,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.video_library_outlined,
              size: 60, color: Colors.white.withOpacity(0.3)),
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _loadHistory,
            icon: const Icon(Icons.refresh, color: Colors.white),
            label: const Text('Retry', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoList(bool isWide) {
    if (_videoList.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off,
                size: 60, color: Colors.white.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text(
              'No recordings found',
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _videoList.length,
      itemBuilder: (context, index) {
        final video = _videoList[index];
        final frameCount = video['frame_count'] as int;
        final startTime = video['start_time'] as String?;
        final thumbnail = video['first_thumbnail'] as String?;

        return Card(
          color: Colors.white.withOpacity(0.06),
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.lightBlueAccent.withOpacity(0.3)),
          ),
          child: InkWell(
            onTap: () => _openVideo(index),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: isWide ? 120 : 80,
                    height: isWide ? 68 : 50,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Colors.lightBlueAccent.withOpacity(0.4)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: thumbnail != null && thumbnail.isNotEmpty
                          ? Image.memory(
                        base64Decode(thumbnail),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: isWide ? 240 : 160,
                        errorBuilder: (c, e, s) => const Icon(
                            Icons.videocam,
                            color: Colors.white38,
                            size: 30),
                      )
                          : const Icon(Icons.videocam,
                          color: Colors.white38, size: 30),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.play_circle,
                                color: Colors.greenAccent, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Recording ${index + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(Icons.calendar_today,
                                color: Colors.white.withOpacity(0.5),
                                size: 11),
                            const SizedBox(width: 4),
                            Text(
                              _formatDateTime(startTime),
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.timer,
                                color: Colors.white.withOpacity(0.5),
                                size: 11),
                            const SizedBox(width: 4),
                            Text(
                              '$frameCount frames • ${_formatDuration(frameCount)}',
                              style: TextStyle(
                                color: Colors.lightBlueAccent.withOpacity(0.9),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent.withOpacity(0.15),
                      border: Border.all(
                          color: Colors.greenAccent.withOpacity(0.5)),
                    ),
                    child: const Icon(Icons.play_arrow,
                        color: Colors.greenAccent, size: 22),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideoPlayer(bool isWide) {
    if (_selectedVideoFrames.isEmpty) {
      return Center(
        child: Text(
          'No frames in this video',
          style: TextStyle(color: Colors.white.withOpacity(0.5)),
        ),
      );
    }

    if (_uiImageCache.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.greenAccent),
            const SizedBox(height: 16),
            Text(
              'Preparing video...',
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Decoding ${_selectedVideoFrames.length} frames to GPU cache',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _isPlaying
                    ? Colors.greenAccent.withOpacity(0.6)
                    : Colors.lightBlueAccent.withOpacity(0.3),
                width: _isPlaying ? 2 : 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: ValueListenableBuilder<int>(
                valueListenable: _frameNotifier,
                builder: (context, idx, _) {
                  final safeIdx =
                  idx.clamp(0, _selectedVideoFrames.length - 1);
                  final currentFrame = _selectedVideoFrames[safeIdx];
                  final uiImage = _uiImageCache[safeIdx];

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      if (uiImage != null)
                        Center(
                          child: RawImage(
                            image: uiImage,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.low,
                          ),
                        )
                      else
                        const Center(
                          child: CircularProgressIndicator(
                              color: Colors.greenAccent, strokeWidth: 2),
                        ),
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isPlaying
                                    ? Icons.play_circle_filled
                                    : Icons.access_time,
                                color: _isPlaying
                                    ? Colors.greenAccent
                                    : Colors.lightBlueAccent,
                                size: 12,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _formatDateTime(currentFrame['captured_at']),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: _isPlaying
                                ? Colors.greenAccent.withOpacity(0.9)
                                : Colors.lightBlueAccent.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _isPlaying
                                ? '▶ ${safeIdx + 1} / ${_selectedVideoFrames.length}'
                                : '${safeIdx + 1} / ${_selectedVideoFrames.length}',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      if (_isPlaying)
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.play_arrow,
                                    color: Colors.white, size: 10),
                                SizedBox(width: 4),
                                Text('PLAYING',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _buildPlaybackControls(),
      ],
    );
  }

  Widget _buildPlaybackControls() {
    final totalFrames = _selectedVideoFrames.length;
    if (totalFrames == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (totalFrames > 1)
            ValueListenableBuilder<int>(
              valueListenable: _frameNotifier,
              builder: (context, idx, _) {
                return SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.greenAccent,
                    inactiveTrackColor: Colors.white.withOpacity(0.15),
                    thumbColor: Colors.greenAccent,
                    overlayColor: Colors.greenAccent.withOpacity(0.2),
                    trackHeight: 4,
                  ),
                  child: Slider(
                    value: idx.clamp(0, totalFrames - 1).toDouble(),
                    min: 0,
                    max: (totalFrames - 1).toDouble(),
                    onChanged: (value) {
                      _seekTo(value.round());
                    },
                  ),
                );
              },
            ),
          if (totalFrames > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _formatTimeOnly(
                        _selectedVideoFrames.first['captured_at']),
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    _formatTimeOnly(
                        _selectedVideoFrames.last['captured_at']),
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10,
                    color: Colors.white70, size: 22),
                onPressed: _skipBackward,
                tooltip: 'Back 10 frames',
              ),
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: _isPlaying
                        ? [Colors.redAccent, const Color(0xFFB71C1C)]
                        : [Colors.greenAccent, const Color(0xFF1B5E20)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (_isPlaying
                          ? Colors.redAccent
                          : Colors.greenAccent)
                          .withOpacity(0.4),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 28,
                  ),
                  onPressed: _isPlaying ? _stopPlayback : _startPlayback,
                  tooltip: _isPlaying ? 'Pause' : 'Play',
                ),
              ),
              IconButton(
                icon: const Icon(Icons.forward_10,
                    color: Colors.white70, size: 22),
                onPressed: _skipForward,
                tooltip: 'Forward 10 frames',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [1.0, 2.0, 4.0, 8.0, 16.0].map((speed) {
                      final isSelected = _playbackSpeed == speed;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => _setPlaybackSpeed(speed),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.greenAccent.withOpacity(0.2)
                                  : Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? Colors.greenAccent
                                    : Colors.white.withOpacity(0.15),
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              '${speed.toInt()}x',
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.greenAccent
                                    : Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.restart_alt,
                    color: Colors.white70, size: 20),
                onPressed: () {
                  _stopPlayback();
                  _frameNotifier.value = 0;
                  setState(() => _playbackIndex = 0);
                },
                tooltip: 'Restart',
              ),
            ],
          ),
          ValueListenableBuilder<int>(
            valueListenable: _frameNotifier,
            builder: (context, idx, _) {
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isPlaying ? Icons.movie : Icons.pause_circle_outline,
                      color: _isPlaying ? Colors.greenAccent : Colors.white54,
                      size: 12,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isPlaying
                          ? 'Playing ${idx + 1} / $totalFrames  •  ${_playbackSpeed.toInt()}x'
                          : '$totalFrames frames • ${_uiImageCache.length} cached  •  Click ▶ to play',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class Employee {
  final int id;
  final String empId;
  final String managerName;
  final String email;
  final String mobile;
  final String role;
  final String pcNumber;
  final String password;

  Employee({
    required this.id,
    required this.empId,
    required this.managerName,
    required this.email,
    required this.mobile,
    required this.role,
    required this.pcNumber,
    this.password = '',
  });

  factory Employee.fromJson(Map<String, dynamic> json) {
    return Employee(
      id: json['id'] is int
          ? json['id']
          : int.parse(json['id'].toString()),
      empId: json['emp_id'] ?? '',
      managerName: json['name'] ?? '',
      email: json['email'] ?? '',
      mobile: json['mobile'] ?? '',
      role: json['role'] ?? 'Employee',
      pcNumber: json['pc_number'] != null
          ? json['pc_number'].toString()
          : 'N/A',
    );
  }

  Map<String, dynamic> toCreateJson() {
    return {
      'emp_id': empId,
      'name': managerName,
      'email': email,
      'mobile': mobile,
      'role': role,
      'password': password,
    };
  }

  Map<String, dynamic> toUpdateJson() {
    final Map<String, dynamic> data = {
      'id': id,
      'name': managerName,
      'email': email,
      'mobile': mobile,
      'role': role,
    };
    if (password.isNotEmpty) {
      data['password'] = password;
    }
    return data;
  }
}