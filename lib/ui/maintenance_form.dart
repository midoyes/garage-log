import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../data/database.dart';
import '../data/photo_store.dart';
import '../data/repository.dart';
import '../domain/fuel_calculator.dart';
import '../domain/maintenance_calculator.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';
import 'photo_widgets.dart';

/// 表單內的一列明細（持有自己的 controller）。
class _Row {
  _Row({this.id, String name = '', String qty = '1', String price = ''})
      : name = TextEditingController(text: name),
        qty = TextEditingController(text: qty),
        price = TextEditingController(text: price);

  final String? id;
  final TextEditingController name;
  final TextEditingController qty;
  final TextEditingController price;

  /// 完全沒填（名稱與單價都空）的列：儲存時直接略過，不當成錯誤。
  bool get isBlank => name.text.trim().isEmpty && price.text.trim().isEmpty;

  /// 無法解析的數字會變成 NaN（而不是默默變成 0），交給驗證擋下。
  ItemInput toInput() => ItemInput(
        id: id,
        name: name.text.trim(),
        quantity: parseNumber(qty.text) ?? double.nan,
        unitPrice: parseNumber(price.text) ?? double.nan,
      );

  void dispose() {
    name.dispose();
    qty.dispose();
    price.dispose();
  }
}

/// 表單內的一張照片：[id] 有值 = 已存在資料庫；null = 這次新增的。
class _FormPhoto {
  _FormPhoto({this.id, required this.fileName, this.size = 0});
  final String? id;
  final String fileName;
  final int size;
}

class MaintenanceFormPage extends ConsumerStatefulWidget {
  const MaintenanceFormPage({super.key, required this.vehicle, this.existing});

  final Vehicle vehicle;
  final MaintenanceWithItems? existing;

  @override
  ConsumerState<MaintenanceFormPage> createState() =>
      _MaintenanceFormPageState();
}

class _MaintenanceFormPageState extends ConsumerState<MaintenanceFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _odo;
  late final TextEditingController _note;
  late DateTime _date;
  final List<_Row> _rows = [];

  /// 使用者是否自己動過里程欄位（動過就不再依日期自動帶入）
  bool _odoTouched = false;

  // ── 照片 ──
  final List<_FormPhoto> _photos = [];

  /// 本次新增、尚未存進資料庫的圖檔；放棄編輯時要刪掉，避免留下垃圾檔案
  final List<String> _addedFiles = [];

  /// 編輯時被移除的「既有」照片的圖檔；儲存成功後才刪
  final List<String> _removedFiles = [];
  bool _photosLoaded = false;
  bool _busy = false;
  bool _saved = false;
  PhotoStore? _store;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(e.record.date);

    // 新增時預帶目前里程（可修改），減少輸入。
    final currentOdo = ref.read(currentOdometerProvider);
    _odo = TextEditingController(
      text: e != null
          ? trimNum(e.record.odometer)
          : (currentOdo != null && currentOdo > 0 ? trimNum(currentOdo) : ''),
    );
    _note = TextEditingController(text: e?.record.note ?? '');
    if (e == null) {
      _photosLoaded = true;
    } else {
      _loadPhotos(e.record.id);
    }
    if (e != null) {
      for (final i in e.items) {
        _rows.add(_Row(
          id: i.id,
          name: i.name,
          qty: trimNum(i.quantity),
          price: trimNum(i.unitPrice, digits: 2),
        ));
      }
    }
  }

  /// 編輯時載入這張保養單既有的照片。載入完成前不會把照片清單送去儲存（避免誤刪）。
  Future<void> _loadPhotos(String recordId) async {
    try {
      final all = await ref.read(repoProvider).watchPhotos().first;
      if (!mounted) return;
      setState(() {
        _photos.addAll([
          for (final ph in all)
            if (ph.recordId == recordId)
              _FormPhoto(id: ph.id, fileName: ph.fileName, size: ph.sizeBytes),
        ]);
        _photosLoaded = true;
      });
    } catch (_) {
      // 讀不到照片時維持 _photosLoaded = false：儲存時不動照片
    }
  }

  Future<void> _importPaths(List<String> paths) async {
    final store = await ref.read(photoStoreProvider.future);
    _store = store;
    if (!mounted) return;
    setState(() => _busy = true);
    var failed = 0;
    for (final path in paths) {
      try {
        final bytes = await File(path).readAsBytes();
        final r = await store.addFromBytes(bytes);
        _addedFiles.add(r.fileName);
        if (!mounted) {
          await store.delete(r.fileName);
          return;
        }
        setState(() => _photos.add(_FormPhoto(fileName: r.fileName, size: r.size)));
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed > 0) showSnack(context, '有 $failed 張照片無法讀取，已略過');
  }

  Future<void> _pickFromFiles() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.image, allowMultiple: true);
    if (res == null) return;
    await _importPaths([
      for (final f in res.files)
        if (f.path != null) f.path!,
    ]);
  }

  Future<void> _takePhoto() async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 90,
      );
      if (x == null) return;
      await _importPaths([x.path]);
    } catch (e) {
      if (mounted) showSnack(context, '無法開啟相機：$e');
    }
  }

  void _removePhoto(_FormPhoto ph) {
    setState(() => _photos.remove(ph));
    if (ph.id == null) {
      // 這次才加的：直接刪檔
      _addedFiles.remove(ph.fileName);
      _store?.delete(ph.fileName);
    } else {
      _removedFiles.add(ph.fileName);
    }
  }

  @override
  void dispose() {
    if (!_saved) {
      // 放棄編輯：把這次新增、沒存進資料庫的圖檔刪掉
      for (final f in _addedFiles) {
        _store?.delete(f);
      }
    }
    _odo.dispose();
    _note.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  double get _total =>
      computeItemsTotal(_rows.where((r) => !r.isBlank).map((r) => r.toInput()));

  /// 常用項目：這台車自訂的（保養週期設定）優先，再接車種預設，名稱不重複。
  List<String> _quickItems() {
    final plans = ref.watch(plansProvider).valueOrNull ?? const <MaintenancePlan>[];
    final seen = <String>{};
    final result = <String>[];
    for (final name in [
      for (final p in plans) p.name,
      ...quickItemsFor(widget.vehicle.type),
    ]) {
      if (seen.add(normalizeItemName(name))) result.add(name);
    }
    return result;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() {
      _date = picked;
      // 新增時、使用者還沒自己填里程：依新日期帶入「該日期之前最近的里程」，
      // 不再沿用目前最新里程（補登舊紀錄時那個值一定是錯的）。
      if (widget.existing == null && !_odoTouched) {
        final b = odometerBounds(readings: _readings(), date: _date);
        _odo.text = b.prevMax == null ? '' : trimNum(b.prevMax!);
      }
    });
  }

  /// 這台車所有加油 + 保養的里程讀數（跨類型一起判定）。
  List<OdometerReading> _readings() {
    final logs = ref.read(fuelLogsProvider).valueOrNull ?? const <FuelLog>[];
    final maint =
        ref.read(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];
    return [
      for (final l in logs)
        OdometerReading(
          id: l.id,
          date: DateTime.fromMillisecondsSinceEpoch(l.date),
          odometer: l.odometer,
          label: '加油',
        ),
      for (final m in maint)
        OdometerReading(
          id: m.record.id,
          date: DateTime.fromMillisecondsSinceEpoch(m.record.date),
          odometer: m.record.odometer,
          label: '保養',
        ),
    ];
  }

  void _addRow([String name = '']) {
    setState(() => _rows.add(_Row(name: name)));
  }

  void _removeRow(_Row row) {
    setState(() => _rows.remove(row));
    // 先讓畫面重建完，再釋放 controller，避免畫面還在使用。
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_busy) {
      showSnack(context, '照片處理中，請稍候');
      return;
    }
    try {
      await ref.read(repoProvider).saveMaintenance(
            id: widget.existing?.record.id,
            vehicleId: widget.vehicle.id,
            date: _date,
            odometer: parseNumber(_odo.text)!,
            items: [
              for (final r in _rows)
                if (!r.isBlank) r.toInput(),
            ],
            note: _note.text,
            photos: _photosLoaded
                ? [
                    for (final ph in _photos)
                      PhotoInput(id: ph.id, fileName: ph.fileName, sizeBytes: ph.size),
                  ]
                : null,
          );
      _saved = true;
      // 儲存成功後，才把「被移除的既有照片」的圖檔刪掉
      final store = _store ?? await ref.read(photoStoreProvider.future);
      for (final f in _removedFiles) {
        await store.delete(f);
      }
      if (mounted) Navigator.of(context).pop();
    } on GarageValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(fuelLogsProvider);
    ref.watch(maintenanceProvider);
    final bounds = odometerBounds(
      readings: _readings(),
      date: _date,
      excludeId: widget.existing?.record.id,
    );
    final odoHelper = odometerHelperText(bounds.prevMax, bounds.nextMin);
    return FormScaffold(
      title: widget.existing == null ? '新增保養' : '編輯保養',
      onSave: _save,
      bottom: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('總金額', style: theme.textTheme.titleMedium),
          Text('\$${fmtMoney(_total)}', style: theme.textTheme.headlineSmall),
        ],
      ),
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: fieldDecoration('日期'),
                  child: Row(
                    children: [
                      Expanded(child: Text(fmtDate(_date))),
                      const Icon(Icons.calendar_today, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _odo,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration('里程', suffix: 'km')
                    .copyWith(helperText: odoHelper, helperMaxLines: 2),
                onChanged: (_) => _odoTouched = true,
                validator: (v) {
                  final err = nonNegativeNumber(v);
                  if (err != null) return err;
                  return validateOdometerByDate(
                    readings: _readings(),
                    date: _date,
                    odometer: parseNumber(v)!,
                    initialOdometer: widget.vehicle.initialOdometer,
                    excludeId: widget.existing?.record.id,
                  );
                },
              ),
              const SizedBox(height: 20),
              Text('常用項目（點一下加入）', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final n in _quickItems())
                    ActionChip(label: Text(n), onPressed: () => _addRow(n)),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('保養明細', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addRow,
                    icon: const Icon(Icons.add),
                    label: const Text('自訂項目'),
                  ),
                ],
              ),
              if (_rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    '尚未加入項目',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                ),
              for (final row in _rows)
                _ItemEditor(
                  key: ObjectKey(row),
                  row: row,
                  onChanged: () => setState(() {}),
                  onRemove: () => _removeRow(row),
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _note,
                decoration: fieldDecoration('備註（選填）'),
                maxLines: 2,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('照片（${_photos.length}）', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  if (Platform.isAndroid)
                    TextButton.icon(
                      onPressed: _busy ? null : _takePhoto,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('拍照'),
                    ),
                  TextButton.icon(
                    onPressed: _busy ? null : _pickFromFiles,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(Platform.isAndroid ? '相簿' : '選擇照片'),
                  ),
                ],
              ),
              if (_photos.isEmpty && !_busy)
                Text(
                  '可附上單據、零件或維修前後的照片（不限張數，會自動縮小以節省空間）',
                  style: theme.textTheme.bodySmall,
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < _photos.length; i++)
                    Stack(
                      key: ValueKey(_photos[i].fileName),
                      children: [
                        PhotoThumb(
                          fileName: _photos[i].fileName,
                          size: 88,
                          onTap: () => openPhotoViewer(
                            context,
                            [for (final x in _photos) x.fileName],
                            i,
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Material(
                            color: Colors.black54,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => _removePhoto(_photos[i]),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close, size: 16, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (_busy)
                    const SizedBox(
                      width: 88,
                      height: 88,
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 單一明細：名稱 / 數量＋單價 / 小計，上下分層，手機窄螢幕也不會擠在一行。
class _ItemEditor extends StatelessWidget {
  const _ItemEditor({
    super.key,
    required this.row,
    required this.onChanged,
    required this.onRemove,
  });

  final _Row row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: row.name,
                    decoration: fieldDecoration('項目名稱'),
                    onChanged: (_) => onChanged(),
                    validator: (v) => row.isBlank
                        ? null
                        : ((v == null || v.trim().isEmpty) ? '請輸入項目名稱' : null),
                  ),
                ),
                IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.close),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: row.qty,
                      keyboardType: numberKeyboard,
                      decoration: fieldDecoration('數量'),
                      onChanged: (_) => onChanged(),
                      validator: (v) => row.isBlank ? null : positiveNumber(v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: row.price,
                      keyboardType: numberKeyboard,
                      decoration: fieldDecoration('單價', suffix: '\$'),
                      onChanged: (_) => onChanged(),
                      validator: (v) => row.isBlank ? null : nonNegativeNumber(v),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text('小計  ', style: theme.textTheme.bodyMedium),
                  Text(
                    '\$${fmtMoney(row.toInput().subtotal)}',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
