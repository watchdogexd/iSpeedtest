import 'dart:async';

import 'package:flutter/material.dart';

import 'src/speed_test_models.dart';
import 'src/speed_test_service.dart';
import 'src/theme_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final themePreferences = ThemePreferences();
  final initialThemeColorId = await themePreferences.loadThemeColorId();
  runApp(
    AppleSpeedApp(
      initialThemeColorId: _resolveThemeColorId(initialThemeColorId),
      themePreferences: themePreferences,
    ),
  );
}

const List<AppThemeColor> appThemeColors = <AppThemeColor>[
  AppThemeColor(id: 'teal', label: '青绿', color: Color(0xFF0B6E6E)),
  AppThemeColor(id: 'blue', label: '蓝色', color: Color(0xFF0061A4)),
  AppThemeColor(id: 'green', label: '绿色', color: Color(0xFF386A20)),
  AppThemeColor(id: 'purple', label: '紫色', color: Color(0xFF6750A4)),
  AppThemeColor(id: 'orange', label: '橙色', color: Color(0xFFB55D00)),
  AppThemeColor(id: 'rose', label: '玫红', color: Color(0xFFB3261E)),
];

class AppThemeColor {
  const AppThemeColor({
    required this.id,
    required this.label,
    required this.color,
  });

  final String id;
  final String label;
  final Color color;
}

class AppleSpeedApp extends StatefulWidget {
  const AppleSpeedApp({
    super.key,
    this.service,
    this.autoLoadEndpoints = true,
    this.initialThemeColorId,
    this.themePreferences = const ThemePreferences(),
  });

  final SpeedTestService? service;
  final bool autoLoadEndpoints;
  final String? initialThemeColorId;
  final ThemePreferences themePreferences;

  @override
  State<AppleSpeedApp> createState() => _AppleSpeedAppState();
}

class _AppleSpeedAppState extends State<AppleSpeedApp> {
  late String _selectedThemeColorId;

  @override
  void initState() {
    super.initState();
    _selectedThemeColorId = _resolveThemeColorId(widget.initialThemeColorId);
  }

  AppThemeColor get _selectedThemeColor {
    return appThemeColors.firstWhere(
      (option) => option.id == _selectedThemeColorId,
      orElse: () => appThemeColors.first,
    );
  }

  @override
  Widget build(BuildContext context) {
    final seedColor = _selectedThemeColor.color;
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ).copyWith(
          surface: const Color(0xFF122027),
          surfaceContainer: const Color(0xFF183038),
          surfaceContainerHigh: const Color(0xFF1B353D),
          surfaceContainerHighest: const Color(0xFF23434C),
        );

    return MaterialApp(
      title: 'iSpeedtest',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF091317),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF091317),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
      home: SpeedTestPage(
        service: widget.service ?? SpeedTestService(),
        autoLoadEndpoints: widget.autoLoadEndpoints,
        themeColors: appThemeColors,
        selectedThemeColorId: _selectedThemeColorId,
        onThemeColorChanged: (id) {
          final themeColorId = _resolveThemeColorId(id);
          setState(() {
            _selectedThemeColorId = themeColorId;
          });
          unawaited(widget.themePreferences.saveThemeColorId(themeColorId));
        },
      ),
    );
  }
}

String _resolveThemeColorId(String? themeColorId) {
  if (themeColorId == null) {
    return appThemeColors.first.id;
  }

  final normalizedThemeColorId = themeColorId.trim();
  return appThemeColors.any((option) => option.id == normalizedThemeColorId)
      ? normalizedThemeColorId
      : appThemeColors.first.id;
}

class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage({
    super.key,
    required this.service,
    required this.themeColors,
    required this.selectedThemeColorId,
    required this.onThemeColorChanged,
    this.autoLoadEndpoints = true,
  });

  final SpeedTestService service;
  final List<AppThemeColor> themeColors;
  final String selectedThemeColorId;
  final ValueChanged<String> onThemeColorChanged;
  final bool autoLoadEndpoints;

  @override
  State<SpeedTestPage> createState() => _SpeedTestPageState();
}

class _SpeedTestPageState extends State<SpeedTestPage> {
  late final SpeedTestService _service;

  final List<String> _customHosts = <String>[];
  SpeedTestPhase _phase = SpeedTestPhase.idle;
  SpeedTestMode _mode = SpeedTestMode.multiThread;
  DohProvider _dohProvider = DohProvider.aliyun;
  String _statusMessage = '准备就绪';
  String _endpoint = '等待测速节点';
  double _currentMbps = 0;
  double _downloadMbps = 0;
  double _uploadMbps = 0;
  double _progressValue = 0;
  double _phaseProgress = 0;
  int _downloadedBytes = 0;
  int _uploadedBytes = 0;
  DateTime? _finishedAt;
  String? _errorMessage;
  String? _usedIp;
  TargetIpInfo? _targetIpInfo;
  int _targetIpInfoRequestId = 0;

  bool _loadingEndpoints = true;
  String? _endpointLoadError;
  List<SpeedTestEndpointOption> _endpoints = const [];
  String? _selectedEndpointId;
  String _selectedIpId = 'auto';

  bool get _isRunning => switch (_phase) {
    SpeedTestPhase.preparing ||
    SpeedTestPhase.downloading ||
    SpeedTestPhase.uploading => true,
    _ => false,
  };

  SpeedTestEndpointOption? get _selectedEndpoint {
    if (_endpoints.isEmpty || _selectedEndpointId == null) {
      return null;
    }

    for (final endpoint in _endpoints) {
      if (endpoint.id == _selectedEndpointId) {
        return endpoint;
      }
    }

    return null;
  }

  ResolvedAddressOption? get _selectedIpOption {
    final endpoint = _selectedEndpoint;
    if (endpoint == null) {
      return null;
    }

    for (final option in endpoint.resolution.selectableAddresses) {
      if (option.id == _selectedIpId) {
        return option;
      }
    }

    return endpoint.resolution.selectableAddresses.firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _service = widget.service;
    if (widget.autoLoadEndpoints) {
      _loadEndpoints();
    } else {
      _loadingEndpoints = false;
    }
  }

  @override
  void dispose() {
    _service.cancel();
    super.dispose();
  }

  Future<void> _loadEndpoints() async {
    setState(() {
      _loadingEndpoints = true;
      _endpointLoadError = null;
    });

    try {
      final bootstrap = await _service.bootstrap(
        provider: _dohProvider,
        customHosts: _customHosts,
      );
      if (!mounted) {
        return;
      }

      final nextSelectedEndpoint =
          bootstrap.endpoints.any(
            (endpoint) => endpoint.id == _selectedEndpointId,
          )
          ? _selectedEndpointId
          : bootstrap.endpoints.firstOrNull?.id;

      final selectedEndpoint = bootstrap.endpoints
          .where((endpoint) => endpoint.id == nextSelectedEndpoint)
          .firstOrNull;
      final ipChoices =
          selectedEndpoint?.resolution.selectableAddresses ?? const [];
      final nextSelectedIp = ipChoices.any((item) => item.id == _selectedIpId)
          ? _selectedIpId
          : (ipChoices.firstOrNull?.id ?? 'auto');

      setState(() {
        _loadingEndpoints = false;
        _endpointLoadError = null;
        _endpoints = bootstrap.endpoints;
        _selectedEndpointId = nextSelectedEndpoint;
        _selectedIpId = nextSelectedIp;
        _endpoint = selectedEndpoint == null
            ? '等待测速节点'
            : sanitizeEndpointHost(selectedEndpoint.host);
        _usedIp = null;
        _targetIpInfo = null;
      });

      unawaited(_refreshTargetIpInfo());
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadingEndpoints = false;
        _endpointLoadError = error.toString();
      });
    }
  }

  Future<void> _startTest() async {
    if (_isRunning) {
      return;
    }

    final selectedEndpoint = _selectedEndpoint;
    final selectedIpOption = _selectedIpOption;
    if (selectedEndpoint == null) {
      setState(() {
        _phase = SpeedTestPhase.error;
        _statusMessage = '没有可用测速节点';
        _errorMessage = '请先加载或添加一个测速节点';
      });
      return;
    }

    setState(() {
      _phase = SpeedTestPhase.preparing;
      _statusMessage = '正在获取 Apple 测速配置';
      _endpoint = sanitizeEndpointHost(selectedEndpoint.host);
      _targetIpInfoRequestId++;
      _targetIpInfo = null;
      _usedIp = null;
      _currentMbps = 0;
      _downloadMbps = 0;
      _uploadMbps = 0;
      _progressValue = 0.03;
      _phaseProgress = 0.15;
      _downloadedBytes = 0;
      _uploadedBytes = 0;
      _finishedAt = null;
      _errorMessage = null;
    });

    try {
      final result = await _service.run(
        options: SpeedTestOptions(
          mode: _mode,
          endpointHost: selectedEndpoint.host,
          selectedIp: selectedIpOption?.address,
          dohProvider: _dohProvider,
        ),
        onProgress: _handleProgress,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _phase = SpeedTestPhase.completed;
        _statusMessage = '测速完成';
        _endpoint = result.endpoint;
        _usedIp = result.usedIp;
        _currentMbps = 0;
        _downloadMbps = result.downloadMbps;
        _uploadMbps = result.uploadMbps;
        _progressValue = 1;
        _phaseProgress = 1;
        _downloadedBytes = result.downloadedBytes;
        _uploadedBytes = result.uploadedBytes;
        _finishedAt = result.finishedAt;
      });

      unawaited(_refreshTargetIpInfo(query: result.usedIp));
    } on SpeedTestCancelled {
      if (!mounted) {
        return;
      }

      setState(() {
        _phase = SpeedTestPhase.cancelled;
        _statusMessage = '测速已取消';
        _targetIpInfo = null;
        _currentMbps = 0;
        _progressValue = 0;
        _phaseProgress = 0;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _phase = SpeedTestPhase.error;
        _statusMessage = '测速失败';
        _targetIpInfo = null;
        _currentMbps = 0;
        _progressValue = 0;
        _phaseProgress = 0;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _refreshTargetIpInfo({String? query}) async {
    final endpoint = _selectedEndpoint;
    final selectedIp = _selectedIpOption;
    final resolvedQuery = query?.trim().isNotEmpty == true
        ? query!.trim()
        : selectedIp?.address ??
              endpoint?.resolution.allAddresses.firstOrNull ??
              endpoint?.host;
    final requestId = ++_targetIpInfoRequestId;
    final endpointId = endpoint?.id;
    final ipId = selectedIp?.id;
    final info = await _service.fetchTargetIpInfo(query: resolvedQuery);
    if (!mounted) {
      return;
    }

    if (requestId != _targetIpInfoRequestId ||
        endpointId != _selectedEndpointId ||
        ipId != _selectedIpId) {
      return;
    }

    setState(() {
      _targetIpInfo = info;
    });
  }

  void _handleProgress(SpeedTestProgress progress) {
    if (!mounted) {
      return;
    }

    setState(() {
      _phase = progress.phase;
      _statusMessage = progress.statusMessage;
      _endpoint = progress.endpoint ?? _endpoint;
      _usedIp = progress.usedIp ?? _usedIp;
      _currentMbps = progress.currentMbps ?? _currentMbps;
      _downloadMbps = progress.downloadMbps ?? _downloadMbps;
      _uploadMbps = progress.uploadMbps ?? _uploadMbps;
      _progressValue = progress.overallProgress ?? _progressValue;
      _phaseProgress = progress.phaseProgress ?? _phaseProgress;
      _downloadedBytes = progress.downloadedBytes ?? _downloadedBytes;
      _uploadedBytes = progress.uploadedBytes ?? _uploadedBytes;
      _mode = progress.mode ?? _mode;
    });
  }

  void _stopTest() {
    _service.cancel();
  }

  Future<void> _showAddNodeDialog() async {
    final addedHost = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _AddNodeSheet(existingHosts: _customHosts.toSet()),
    );

    if (!mounted || addedHost == null) {
      return;
    }

    if (_customHosts.contains(addedHost)) {
      return;
    }

    _customHosts.add(addedHost);
    await _loadEndpoints();
  }

  Future<void> _selectEndpoint() async {
    if (_isRunning || _loadingEndpoints || _endpoints.isEmpty) {
      return;
    }

    final selectedValue = await _showOptionPicker<String>(
      title: '选择测速节点',
      selectedValue: _selectedEndpointId,
      options: _endpoints
          .map(
            (endpoint) => _DropdownOption<String>(
              value: endpoint.id,
              label: '${endpoint.label} · ${endpoint.host}',
            ),
          )
          .toList(),
    );

    if (!mounted ||
        selectedValue == null ||
        selectedValue == _selectedEndpointId) {
      return;
    }

    final endpoint = _endpoints
        .where((item) => item.id == selectedValue)
        .firstOrNull;
    setState(() {
      _selectedEndpointId = selectedValue;
      _selectedIpId =
          endpoint?.resolution.selectableAddresses.firstOrNull?.id ?? 'auto';
      _usedIp = null;
      _targetIpInfo = null;
    });
    unawaited(_refreshTargetIpInfo());
  }

  Future<void> _selectIp() async {
    final endpoint = _selectedEndpoint;
    if (_isRunning || endpoint == null) {
      return;
    }

    final selectedValue = await _showOptionPicker<String>(
      title: '选择测速 IP',
      selectedValue: _selectedIpId,
      options: endpoint.resolution.selectableAddresses
          .map(
            (item) => _DropdownOption<String>(
              value: item.id,
              label: item.address == null
                  ? item.label
                  : '${item.label} · ${item.family}',
            ),
          )
          .toList(),
    );

    if (!mounted || selectedValue == null || selectedValue == _selectedIpId) {
      return;
    }

    setState(() {
      _selectedIpId = selectedValue;
      _usedIp = null;
      _targetIpInfo = null;
    });
    unawaited(_refreshTargetIpInfo());
  }

  Future<void> _showThemeColorPicker() async {
    if (_isRunning) {
      return;
    }

    final selectedValue = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _ThemeColorPickerSheet(
        colors: widget.themeColors,
        selectedId: widget.selectedThemeColorId,
      ),
    );

    if (!mounted ||
        selectedValue == null ||
        selectedValue == widget.selectedThemeColorId) {
      return;
    }

    widget.onThemeColorChanged(selectedValue);
  }

  Future<T?> _showOptionPicker<T>({
    required String title,
    required T? selectedValue,
    required List<_DropdownOption<T>> options,
  }) {
    if (options.isEmpty) {
      return Future<T?>.value(null);
    }

    return showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _OptionPickerSheet<T>(
        title: title,
        selectedValue: selectedValue,
        options: options,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selectedEndpoint = _selectedEndpoint;
    final selectedIpOption = _selectedIpOption;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'iSpeedtest',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.05,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  tooltip: '刷新节点',
                  onPressed: _loadingEndpoints || _isRunning
                      ? null
                      : _loadEndpoints,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '添加节点',
                  onPressed: _isRunning ? null : _showAddNodeDialog,
                  icon: const Icon(Icons.add_link_rounded),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: '主题颜色',
                  onPressed: _isRunning ? null : _showThemeColorPicker,
                  icon: const Icon(Icons.palette_rounded),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _HeroPanel(
              currentMbps: _currentMbps,
              phase: _phase,
              statusMessage: _statusMessage,
              endpoint: _heroEndpointHost,
              connectionIp: _heroConnectionIp,
              progress: _progressValue,
              phaseProgress: _phaseProgress,
              progressCaption: _progressCaption,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isRunning || _loadingEndpoints
                        ? null
                        : _startTest,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('开始测速'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRunning ? _stopTest : null,
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('停止'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    title: '下载',
                    value: _downloadMbps,
                    icon: Icons.south_rounded,
                    accentColor: colorScheme.primary,
                    bytesLabel: _formatBytes(_downloadedBytes),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MetricCard(
                    title: '上传',
                    value: _uploadMbps,
                    icon: Icons.north_rounded,
                    accentColor: colorScheme.tertiary,
                    bytesLabel: _formatBytes(_uploadedBytes),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '测速模式',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<SpeedTestMode>(
                      showSelectedIcon: false,
                      segments: SpeedTestMode.values
                          .map(
                            (mode) => ButtonSegment<SpeedTestMode>(
                              value: mode,
                              label: Text(mode.label),
                            ),
                          )
                          .toList(),
                      selected: <SpeedTestMode>{_mode},
                      onSelectionChanged: _isRunning
                          ? null
                          : (selection) {
                              setState(() {
                                _mode = selection.first;
                              });
                            },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DoH 提供商',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<DohProvider>(
                      showSelectedIcon: false,
                      segments: DohProvider.values
                          .map(
                            (provider) => ButtonSegment<DohProvider>(
                              value: provider,
                              label: Text(provider.label),
                            ),
                          )
                          .toList(),
                      selected: <DohProvider>{_dohProvider},
                      onSelectionChanged: _isRunning || _loadingEndpoints
                          ? null
                          : (selection) async {
                              setState(() {
                                _dohProvider = selection.first;
                              });
                              await _loadEndpoints();
                            },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '测速节点',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (_loadingEndpoints)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _SelectionField(
                      label: '选择测速节点',
                      value: selectedEndpoint == null
                          ? '暂无可用节点'
                          : '${selectedEndpoint.label} · ${selectedEndpoint.host}',
                      hint: '暂无可用节点',
                      enabled:
                          !_isRunning &&
                          !_loadingEndpoints &&
                          _endpoints.isNotEmpty,
                      onTap: _selectEndpoint,
                    ),
                    if (selectedEndpoint != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        selectedEndpoint.description,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _SelectionField(
                        label: '选择测速 IP',
                        value: selectedIpOption == null
                            ? '自动选择'
                            : (selectedIpOption.address == null
                                  ? selectedIpOption.label
                                  : '${selectedIpOption.label} · ${selectedIpOption.family}'),
                        hint: '自动选择',
                        enabled: !_isRunning,
                        onTap: _selectIp,
                      ),
                      const SizedBox(height: 12),
                      _ResolutionWrap(
                        title: 'DoH 预解析',
                        values: selectedEndpoint.resolution.allAddresses,
                        footer: '解析器: ${selectedEndpoint.resolution.resolver}',
                      ),
                      if (selectedIpOption != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          selectedIpOption.address == null
                              ? '测速连接: 自动选择解析结果'
                              : '测速连接: 固定到 ${selectedIpOption.address}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ],
                    if (_endpointLoadError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        '节点加载失败: $_endpointLoadError',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_targetIpInfo != null) const SizedBox(height: 16),
            if (_targetIpInfo != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '目标 IP 信息',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _InfoLine(label: 'IP', value: _targetIpInfo!.query),
                      _InfoLine(
                        label: 'ASN',
                        value: _targetIpInfo!.asn.isEmpty
                            ? '未知'
                            : _targetIpInfo!.asn,
                      ),
                      _InfoLine(
                        label: 'AS Name',
                        value: _targetIpInfo!.asName.isEmpty
                            ? '未知'
                            : _targetIpInfo!.asName,
                      ),
                      _InfoLine(
                        label: '归属地',
                        value: _targetIpInfo!.locationLabel,
                      ),
                      _InfoLine(
                        label: 'ISP',
                        value: _targetIpInfo!.isp.isEmpty
                            ? (_targetIpInfo!.org.isEmpty
                                  ? '未知'
                                  : _targetIpInfo!.org)
                            : _targetIpInfo!.isp,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_finishedAt != null || _usedIp != null || _errorMessage != null)
              const SizedBox(height: 16),
            if (_finishedAt != null || _usedIp != null || _errorMessage != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_finishedAt != null)
                        Text(
                          '最近完成时间: ${_formatTime(_finishedAt!)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                      if (_usedIp != null) ...[
                        if (_finishedAt != null) const SizedBox(height: 8),
                        Text(
                          '最近测速 IP: $_usedIp',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.25,
                          ),
                        ),
                      ],
                      if (_errorMessage != null) ...[
                        if (_finishedAt != null || _usedIp != null)
                          const SizedBox(height: 12),
                        Text(
                          '错误详情: $_errorMessage',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.error,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String get _progressCaption {
    return switch (_phase) {
      SpeedTestPhase.preparing => '准备阶段',
      SpeedTestPhase.downloading => '下载测试',
      SpeedTestPhase.uploading => '上传测试',
      SpeedTestPhase.completed => '测试完成',
      SpeedTestPhase.cancelled => '测速已取消',
      SpeedTestPhase.error => '测速失败',
      SpeedTestPhase.idle => '等待开始',
    };
  }

  String get _heroEndpointHost {
    return sanitizeEndpointHost(_endpoint);
  }

  String? get _heroConnectionIp {
    final usedIp = _usedIp?.trim();
    if (usedIp == null || usedIp.isEmpty) {
      return null;
    }

    if (_heroEndpointHost == usedIp || _endpoint.contains(usedIp)) {
      return null;
    }

    return usedIp;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) {
      return '0 B';
    }

    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }

    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unitIndex]}';
  }

  String _formatTime(DateTime time) {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

class _ThemeColorPickerSheet extends StatelessWidget {
  const _ThemeColorPickerSheet({
    required this.colors,
    required this.selectedId,
  });

  final List<AppThemeColor> colors;
  final String selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '主题颜色',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: colors.map((option) {
              final isSelected = option.id == selectedId;
              final foreground =
                  ThemeData.estimateBrightnessForColor(option.color) ==
                      Brightness.dark
                  ? Colors.white
                  : Colors.black;

              return Tooltip(
                message: option.label,
                child: Semantics(
                  button: true,
                  selected: isSelected,
                  label: '主题颜色 ${option.label}',
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop(option.id),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: option.color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            width: isSelected ? 3 : 1,
                            color: isSelected
                                ? colorScheme.onSurface
                                : colorScheme.outlineVariant,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: option.color.withValues(alpha: 0.35),
                                    blurRadius: 16,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 120),
                          opacity: isSelected ? 1 : 0,
                          child: Icon(
                            Icons.check_rounded,
                            color: foreground,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({
    required this.currentMbps,
    required this.phase,
    required this.statusMessage,
    required this.endpoint,
    required this.connectionIp,
    required this.progress,
    required this.phaseProgress,
    required this.progressCaption,
  });

  final double currentMbps;
  final SpeedTestPhase phase;
  final String statusMessage;
  final String endpoint;
  final String? connectionIp;
  final double progress;
  final double phaseProgress;
  final String progressCaption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final progressValue = progress.clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前速度',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${currentMbps.toStringAsFixed(currentMbps >= 100 ? 0 : 2)} Mbps',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        height: 0.95,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      statusMessage,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: progressValue),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            builder: (context, animatedValue, child) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: animatedValue,
                  minHeight: 7,
                  backgroundColor: colorScheme.surfaceContainer,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    colorScheme.primary,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                progressCaption,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.2,
                ),
              ),
              const Spacer(),
              if (switch (phase) {
                SpeedTestPhase.preparing ||
                SpeedTestPhase.downloading ||
                SpeedTestPhase.uploading ||
                SpeedTestPhase.completed => true,
                _ => false,
              })
                Text(
                  '${(phaseProgress * 100).clamp(0, 100).round()}%',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前节点',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  endpoint,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                if (connectionIp != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '连接 IP: $connectionIp',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.accentColor,
    required this.bytesLabel,
  });

  final String title;
  final double value;
  final IconData icon;
  final Color accentColor;
  final String bytesLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: accentColor),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value.toStringAsFixed(value >= 100 ? 0 : 2),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                height: 0.95,
              ),
            ),
            Text(
              'Mbps',
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '已传输 $bytesLabel',
              style: theme.textTheme.bodySmall?.copyWith(
                height: 1.25,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResolutionWrap extends StatelessWidget {
  const _ResolutionWrap({
    required this.title,
    required this.values,
    required this.footer,
  });

  final String title;
  final List<String> values;
  final String footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: values.isEmpty
              ? const [Chip(label: Text('暂无解析结果'))]
              : values.map((value) => Chip(label: Text(value))).toList(),
        ),
        const SizedBox(height: 8),
        Text(
          footer,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SelectionField extends StatelessWidget {
  const _SelectionField({
    required this.label,
    required this.value,
    required this.hint,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String? value;
  final String hint;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final displayText = value?.trim().isNotEmpty == true ? value! : hint;
    final textColor = value?.trim().isNotEmpty == true
        ? colorScheme.onSurface
        : colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer.withValues(
              alpha: enabled ? 0.45 : 0.28,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(
                alpha: enabled ? 1 : 0.65,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      displayText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: enabled
                    ? colorScheme.onSurfaceVariant
                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DropdownOption<T> {
  const _DropdownOption({required this.value, required this.label});

  final T value;
  final String label;
}

class _OptionPickerSheet<T> extends StatelessWidget {
  const _OptionPickerSheet({
    required this.title,
    required this.selectedValue,
    required this.options,
  });

  final String title;
  final T? selectedValue;
  final List<_DropdownOption<T>> options;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final safeMaxHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final availableHeight = safeMaxHeight > 32
            ? safeMaxHeight - 32
            : safeMaxHeight;
        final desiredHeight = 104.0 + (options.length * 72.0);
        final sheetHeight = desiredHeight.clamp(220.0, availableHeight);

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SizedBox(
            height: sheetHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ListView.separated(
                    itemCount: options.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final option = options[index];
                      final isSelected = option.value == selectedValue;

                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => Navigator.of(context).pop(option.value),
                          child: Ink(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? colorScheme.primary.withValues(alpha: 0.14)
                                  : colorScheme.surfaceContainer.withValues(
                                      alpha: 0.4,
                                    ),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: isSelected
                                    ? colorScheme.primary.withValues(alpha: 0.7)
                                    : colorScheme.outlineVariant,
                              ),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    option.label,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  isSelected
                                      ? Icons.check_circle_rounded
                                      : Icons.chevron_right_rounded,
                                  color: isSelected
                                      ? colorScheme.primary
                                      : colorScheme.onSurfaceVariant,
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
            ),
          ),
        );
      },
    );
  }
}

class _AddNodeSheet extends StatefulWidget {
  const _AddNodeSheet({required this.existingHosts});

  final Set<String> existingHosts;

  @override
  State<_AddNodeSheet> createState() => _AddNodeSheetState();
}

class _AddNodeSheetState extends State<_AddNodeSheet> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _errorText = '请输入节点域名或 IP 地址';
      });
      return;
    }

    final normalized = SpeedTestService.normalizeHost(raw);
    if (normalized == null) {
      setState(() {
        _errorText = '请输入合法的域名或 IP 地址';
      });
      return;
    }

    if (widget.existingHosts.contains(normalized)) {
      setState(() {
        _errorText = '该节点已经存在';
      });
      return;
    }

    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(normalized);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '添加测速节点',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_errorText == null) {
                return;
              }
              setState(() {
                _errorText = null;
              });
            },
            decoration: InputDecoration(
              hintText: '例如 hkhkg1-edge-bx-002.aaplimg.com',
              labelText: '节点域名或 IP',
              errorText: _errorText,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submit,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
