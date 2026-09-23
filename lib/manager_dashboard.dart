import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:grow_logix_admin/Log_In.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String baseUrl = 'http://192.168.1.42/grow_logix/manage_manager.php';
const String liveStreamUrl = 'http://192.168.1.42/grow_logix/live_stream.php';

const List<String> availableRoleChoices = [
  'Website Developer',
  'Video Editor',
  'Social Media Executive',
  'SEO Executive',
  'Data Scrapper',
  'Graphics Designer',
];

class ManagerDashboard extends StatefulWidget {
  const ManagerDashboard({super.key});

  @override
  State<ManagerDashboard> createState() => _ManagerDashboardState();
}

class _ManagerDashboardState extends State<ManagerDashboard> {
  List<Employee> _employees = [];
  bool _isLoading = false;
  String _searchQuery = '';
  String _selectedRoleFilter = 'All';
  int _sortColumnIndex = 0;
  bool _sortAscending = true;

  // Multiple live streams
  final Map<String, LiveStreamSession> _activeSessions = {};
  bool _isRequestSending = false;

  // Caches
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

  bool _shouldShowPlayButton(String role) {
    return _allowedPlayRoles.contains(role.trim().toLowerCase());
  }

  @override
  void initState() {
    super.initState();
    _fetchEmployees();
    // Auto-refresh online status every 30 seconds
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted && _employees.isNotEmpty) {
        _verifyAllEmployees();
      }
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    for (final session in _activeSessions.values) {
      session.dispose();
    }
    super.dispose();
  }

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
          // Verify employees in parallel
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
    // Batch verify — 5 at a time to avoid hammering server
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
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success' && data['employee'] != null) {
          final emp = data['employee'];
          if (mounted) {
            setState(() {
              _pcNumberCache[empId] = emp['pc_number'] ?? 'Personal PC';
              _pcTypeCache[empId] = emp['pc_type'] ?? 'personal';
              _onlineStatusCache[empId] = data['is_online'] == true;
              _deviceIdCache[empId] = emp['device_id'] ?? 'N/A';
              _computerNameCache[empId] = emp['computer_name'] ?? 'N/A';
              _lastSeenCache[empId] = emp['last_seen'] ?? '';
            });
          }
        } else {
          if (mounted) {
            setState(() {
              _onlineStatusCache[empId] = false;
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

  // ==================== LIVE STREAM REQUEST ====================
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

        final pcNumber = data['pc_number'] ??
            _pcNumberCache[emp.empId] ??
            'Personal PC';
        final pcType = data['pc_type'] ?? _pcTypeCache[emp.empId] ?? 'personal';

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

  /// Floating live viewers — responsive positioning
  List<Widget> _buildFloatingViewers(double screenWidth) {
    final List<Widget> viewers = [];
    final expandedSessions = _activeSessions.values
        .where((s) => !s.isMinimized)
        .toList();

    // Responsive size based on screen width
    final viewerWidth = screenWidth > 1400
        ? 560.0
        : screenWidth > 1100
        ? 480.0
        : screenWidth > 900
        ? 420.0
        : screenWidth * 0.9;
    final viewerHeight = viewerWidth * 0.85;

    // Calculate positions for expanded viewers (cascade)
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

    // Minimized sessions → bottom-right stacked
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
              final pcNumber = _pcNumberCache[emp.empId] ?? 'Loading...';
              final pcType = _pcTypeCache[emp.empId] ?? 'personal';
              final isOnline = _onlineStatusCache[emp.empId] ?? false;
              final isOfficePc = pcType == 'office';

              return DataRow(cells: [
                DataCell(Text(emp.empId,
                    style: const TextStyle(color: Colors.white))),
                DataCell(Text(emp.managerName,
                    style: const TextStyle(color: Colors.white))),
                DataCell(
                  Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                          color: isOfficePc
                              ? Colors.greenAccent
                              : Colors.lightBlueAccent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          pcNumber,
                          style: TextStyle(
                            color: isOfficePc
                                ? Colors.greenAccent
                                : Colors.lightBlueAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                          color: isOnline
                              ? Colors.greenAccent
                              : Colors.redAccent,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isOnline ? 'Online' : 'Offline',
                        style: TextStyle(
                          color:
                          isOnline ? Colors.greenAccent : Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                DataCell(
                  Row(
                    children: [
                      if (showPlay)
                        IconButton(
                          onPressed: _isRequestSending || isStreaming
                              ? null
                              : () => _sendLiveRequest(emp),
                          icon: Icon(
                            isStreaming
                                ? Icons.videocam
                                : Icons.play_circle_fill,
                            color: isStreaming
                                ? Colors.greenAccent
                                : (_isRequestSending
                                ? Colors.white38
                                : Colors.white),
                          ),
                          tooltip:
                          isStreaming ? 'Viewing Live' : 'Start Live View',
                        ),
                      IconButton(
                        icon: const Icon(Icons.history,
                            color: Colors.lightBlueAccent),
                        onPressed: () => _showHistoryDialog(emp),
                        tooltip: 'View History',
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
        final pcNumber = _pcNumberCache[emp.empId] ?? 'Loading...';
        final isOnline = _onlineStatusCache[emp.empId] ?? false;

        return Card(
          color: Colors.white.withOpacity(0.06),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor:
              isOnline ? Colors.greenAccent.withOpacity(0.2) : Colors.grey,
              child: Text(
                emp.managerName.isNotEmpty
                    ? emp.managerName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: isOnline ? Colors.greenAccent : Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(
              emp.managerName,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '${emp.empId} | ${emp.role}\n$pcNumber | ${isOnline ? "Online" : "Offline"}',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showPlay)
                  IconButton(
                    onPressed: _isRequestSending || isStreaming
                        ? null
                        : () => _sendLiveRequest(emp),
                    icon: Icon(
                      isStreaming ? Icons.videocam : Icons.play_circle_outline,
                      color: isStreaming
                          ? Colors.greenAccent
                          : (_isRequestSending
                          ? Colors.white38
                          : Colors.white),
                    ),
                  ),
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
                          Text('History', style: TextStyle(color: Colors.white)),
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

  // ==================== EMPLOYEE INFO DIALOG ====================
  void _showEmployeeInfo(Employee emp) {
    final pcNumber = _pcNumberCache[emp.empId] ?? 'Loading...';
    final pcType = _pcTypeCache[emp.empId] ?? 'personal';
    final isOnline = _onlineStatusCache[emp.empId] ?? false;
    final deviceId = _deviceIdCache[emp.empId] ?? 'N/A';
    final computerName = _computerNameCache[emp.empId] ?? 'N/A';
    final lastSeen = _lastSeenCache[emp.empId] ?? 'N/A';

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
                _infoRow('Status', isOnline ? 'Online' : 'Offline',
                    isOnline ? Colors.greenAccent : Colors.redAccent),
                _infoRow(
                    'Device Type',
                    pcType == 'office' ? 'Office PC' : 'Personal PC',
                    pcType == 'office'
                        ? Colors.greenAccent
                        : Colors.lightBlueAccent),
                _infoRow('PC Number', pcNumber, Colors.white),
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

  // ==================== HISTORY DIALOG ====================
  Future<void> _showHistoryDialog(Employee emp) async {
    showDialog(
      context: context,
      builder: (context) {
        return _HistoryDialog(
          empId: emp.empId,
          empName: emp.managerName,
          pcNumber: _pcNumberCache[emp.empId] ?? 'N/A',
          pcType: _pcTypeCache[emp.empId] ?? 'personal',
          deviceId: _deviceIdCache[emp.empId] ?? 'N/A',
          computerName: _computerNameCache[emp.empId] ?? 'N/A',
        );
      },
    );
  }

  void _showEmployeeForm({Employee? employee}) async {
    final formKey = GlobalKey<FormState>();
    final isEditing = employee != null;

    final nameController =
    TextEditingController(text: employee?.managerName ?? '');
    final emailController =
    TextEditingController(text: employee?.email ?? '');
    final mobileController =
    TextEditingController(text: employee?.mobile ?? '');
    final passwordController = TextEditingController();

    String empId = employee?.empId ?? '';
    String selectedRole = employee?.role ?? availableRoleChoices.first;
    bool isSubmitting = false;

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
                          labelText: 'Employee ID',
                          labelStyle: TextStyle(color: Colors.white60),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: nameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Full Name',
                          labelStyle: TextStyle(color: Colors.white60),
                        ),
                        validator: (val) => val == null || val.trim().isEmpty
                            ? 'Enter full name'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: emailController,
                        style: const TextStyle(color: Colors.white),
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email Address',
                          labelStyle: TextStyle(color: Colors.white60),
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
                        ),
                        validator: (val) =>
                        val == null || val.trim().length < 10
                            ? 'Enter valid mobile number'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: availableRoleChoices.contains(selectedRole)
                            ? selectedRole
                            : availableRoleChoices.first,
                        dropdownColor: const Color(0xFF16213E),
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Role',
                          labelStyle: TextStyle(color: Colors.white60),
                        ),
                        items: availableRoleChoices.map((role) {
                          return DropdownMenuItem(
                            value: role,
                            child: Text(role),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => selectedRole = value);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: passwordController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: isEditing
                              ? 'New Password (Optional)'
                              : 'Password',
                          labelStyle: const TextStyle(color: Colors.white60),
                        ),
                        validator: (val) {
                          if (!isEditing &&
                              (val == null || val.trim().length < 6)) {
                            return 'Password must be at least 6 characters';
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
  String? currentFrameBase64;
  int refreshCount = 0;
  String status = 'waiting';
  DateTime? lastFrameTime;
  DateTime? capturedAt;
  bool isPolling = false;
  bool isMinimized = false;
  bool isDisposed = false;

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
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
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
        Uri.parse('$liveStreamUrl?action=get_live_stream&emp_id=$empId'),
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode == 200 && !isDisposed) {
        final data = json.decode(response.body);
        final s = data['status'];

        if (s == 'success' && data['image_base64'] != null) {
          currentFrameBase64 = data['image_base64'];
          refreshCount++;
          status = 'live';
          lastFrameTime = DateTime.now();
          if (data['captured_at'] != null) {
            try {
              capturedAt =
                  DateTime.parse(data['captured_at'].replaceFirst(' ', 'T'));
            } catch (_) {}
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
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
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
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
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
          // Header
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
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
                  icon: const Icon(Icons.close,
                      color: Colors.white70, size: 16),
                  onPressed: () async {
                    await session.stopAndClose();
                    widget.onClose();
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          // Stream view
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
              child: session.currentFrameBase64 == null
                  ? _buildWaitingView()
                  : _buildLiveView(),
            ),
          ),
          const SizedBox(height: 8),
          // Footer
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
                        : 'Waiting for first frame... (updates every 1 min)',
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
              base64Decode(widget.session.currentFrameBase64!),
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
                          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11)),
                    ],
                  ),
                );
              },
            ),
          ),
          // Yellow highlight border (from employee's active window)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.yellow.withOpacity(0.7), width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.yellow.withOpacity(0.2),
                      blurRadius: 15,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 8, left: 8,
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
                        color: Colors.white, fontSize: 9,
                        fontWeight: FontWeight.bold, letterSpacing: 1,
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

// ==================== HISTORY DIALOG ====================
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
  List<Map<String, dynamic>> _frames = [];
  bool _isLoading = true;
  String? _error;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await http.get(
        Uri.parse(
            '$liveStreamUrl?action=get_frame_history&emp_id=${widget.empId}&limit=50'),
        headers: {'Accept': 'application/json'},
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'success' && data['frames'] != null) {
          final List frames = data['frames'];
          if (frames.isEmpty) {
            setState(() {
              _error = 'No captured frames yet';
              _isLoading = false;
            });
          } else {
            setState(() {
              _frames = List<Map<String, dynamic>>.from(frames);
              _selectedIndex = 0;
              _isLoading = false;
            });
          }
        } else {
          setState(() {
            _error = 'No frames found';
            _isLoading = false;
          });
        }
      } else {
        setState(() {
          _error = 'Failed to load: ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  String _formatDateTime(String? dt) {
    if (dt == null || dt.isEmpty) return 'N/A';
    try {
      final parsed = DateTime.parse(dt.replaceFirst(' ', 'T'));
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${parsed.day.toString().padLeft(2, '0')} ${months[parsed.month - 1]} ${parsed.year}  •  ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
    } catch (e) {
      return dt;
    }
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
        width: isWide ? screenWidth * 0.85 : screenWidth * 0.95,
        height: MediaQuery.of(context).size.height * 0.85,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildHeader(isWide),
            const SizedBox(height: 12),
            // Device info bar
            _buildDeviceInfoBar(isWide),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? const Center(
                  child:
                  CircularProgressIndicator(color: Color(0xFFE94560)))
                  : _error != null
                  ? _buildErrorView()
                  : _buildHistoryView(isWide),
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
          child: const Icon(Icons.history,
              color: Colors.lightBlueAccent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Screen Capture History',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              Text(
                '${widget.empName} • ${widget.empId}${_frames.isNotEmpty ? " • ${_frames.length} frames" : ""}',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 11,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white70),
          onPressed: _loadHistory,
          tooltip: 'Refresh',
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
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
              'Device ID: ${widget.deviceId}',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            'PC Name: ${widget.computerName}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 11,
            ),
          ),
        ],
      )
          : Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
          const SizedBox(height: 6),
          Text(
            'Device ID: ${widget.deviceId}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 10,
            ),
            overflow: TextOverflow.ellipsis,
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
          Icon(Icons.image_not_supported_outlined,
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

  Widget _buildHistoryView(bool isWide) {
    final selectedFrame = _frames[_selectedIndex];
    return Column(
      children: [
        // Main preview
        Expanded(
          flex: 3,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.lightBlueAccent.withOpacity(0.3),
                width: 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    base64Decode(selectedFrame['image_base64']),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) {
                      return Center(
                        child: Text(
                          'Invalid image',
                          style:
                          TextStyle(color: Colors.white.withOpacity(0.5)),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.75),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.access_time,
                              color: Colors.lightBlueAccent, size: 12),
                          const SizedBox(width: 6),
                          Text(
                            _formatDateTime(selectedFrame['captured_at']),
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
                        color: Colors.lightBlueAccent.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_selectedIndex + 1} / ${_frames.length}',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Navigation
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _selectedIndex > 0
                    ? () => setState(() => _selectedIndex--)
                    : null,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Previous', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _selectedIndex < _frames.length - 1
                    ? () => setState(() => _selectedIndex++)
                    : null,
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('Next', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Thumbnail strip
        SizedBox(
          height: 76,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _frames.length,
            itemBuilder: (context, index) {
              final isSelected = index == _selectedIndex;
              final frame = _frames[index];
              return GestureDetector(
                onTap: () => setState(() => _selectedIndex = index),
                child: Container(
                  width: 100,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? Colors.lightBlueAccent
                          : Colors.white.withOpacity(0.1),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Column(
                      children: [
                        Expanded(
                          child: Image.memory(
                            base64Decode(frame['image_base64']),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (c, e, s) => Container(
                              color: Colors.black,
                              child: Icon(Icons.broken_image,
                                  color: Colors.white.withOpacity(0.3),
                                  size: 20),
                            ),
                          ),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 3),
                          color: Colors.black.withOpacity(0.75),
                          child: Text(
                            _formatDateTime(frame['captured_at'])
                                .split('•')
                                .last
                                .trim(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
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
      pcNumber:
      json['pc_number'] != null ? json['pc_number'].toString() : 'N/A',
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
    if (password.isNotEmpty) data['password'] = password;
    return data;
  }
}