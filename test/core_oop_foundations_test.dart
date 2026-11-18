import 'package:mybike_app/core/ble/proximity_rssi_tracker.dart';
import 'package:mybike_app/core/services/json_prefs_store.dart';
import 'package:mybike_app/core/utils/app_formatters.dart';
import 'package:mybike_app/core/utils/rssi_distance_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestRecord {
  final String id;
  final int count;

  const _TestRecord({required this.id, required this.count});

  factory _TestRecord.fromJson(Map<String, dynamic> json) {
    return _TestRecord(
      id: (json['id'] as String?) ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'count': count};
}

class _TestJsonStore extends JsonPrefsStore<_TestRecord> {
  Future<_TestRecord?> load(
    String key, {
    List<String> fallbackKeys = const [],
  }) =>
      readObject(key, _TestRecord.fromJson, fallbackKeys: fallbackKeys);

  Future<void> save(String key, _TestRecord item) =>
      writeObject(key, item, (e) => e.toJson());

  Future<List<_TestRecord>?> loadAll(
    String key, {
    bool Function(_TestRecord)? where,
  }) =>
      readList(key, _TestRecord.fromJson, where: where);

  Future<void> saveAll(String key, List<_TestRecord> items) =>
      writeList(key, items, (e) => e.toJson());

  Future<void> deleteAll(Iterable<String> keys) => removeKeys(keys);

  _TestRecord? tryDecode(String raw) =>
      decodeObject(raw, _TestRecord.fromJson);
}

void main() {
  group('AppFormatters', () {
    test('formatDurationClock & formatDurationClockSec', () {
      expect(AppFormatters.formatDurationClock(Duration.zero), '00:00');
      expect(
        AppFormatters.formatDurationClock(const Duration(seconds: -10)),
        '00:00',
      );
      expect(
        AppFormatters.formatDurationClock(const Duration(minutes: 4, seconds: 7)),
        '04:07',
      );
      expect(
        AppFormatters.formatDurationClock(
          const Duration(hours: 2, minutes: 5, seconds: 9),
        ),
        '2:05:09',
      );
      expect(AppFormatters.formatDurationClockSec(-5), '00:00');
      expect(AppFormatters.formatDurationClockSec(0), '00:00');
      expect(AppFormatters.formatDurationClockSec(65), '01:05');
      expect(AppFormatters.formatDurationClockSec(3661), '1:01:01');
    });

    test('formatDurationReadable', () {
      expect(AppFormatters.formatDurationReadable(-1), '0 phút');
      expect(AppFormatters.formatDurationReadable(0), '0 phút');
      expect(AppFormatters.formatDurationReadable(42), '42 giây');
      expect(AppFormatters.formatDurationReadable(180), '3 phút');
      expect(AppFormatters.formatDurationReadable(3600), '1g');
      expect(AppFormatters.formatDurationReadable(3900), '1g 5p');
    });

    test('formatDurationVerboseSec', () {
      expect(AppFormatters.formatDurationVerboseSec(-3), '0 giây');
      expect(AppFormatters.formatDurationVerboseSec(0), '0 giây');
      expect(AppFormatters.formatDurationVerboseSec(15), '15 giây');
      expect(AppFormatters.formatDurationVerboseSec(120), '2 phút');
      expect(AppFormatters.formatDurationVerboseSec(125), '2 phút 5 giây');
      expect(AppFormatters.formatDurationVerboseSec(7200), '2 giờ');
      expect(AppFormatters.formatDurationVerboseSec(7500), '2 giờ 5 phút');
    });

    test('formatKm', () {
      expect(AppFormatters.formatKm(double.nan), '0');
      expect(AppFormatters.formatKm(double.infinity), '0');
      expect(AppFormatters.formatKm(-0.02), '0');
      expect(AppFormatters.formatKm(12.04), '12');
      expect(AppFormatters.formatKm(12.06), '12.1');
      expect(AppFormatters.formatKm(12.96), '13');
    });

    test('formatDateDmY', () {
      expect(
        AppFormatters.formatDateDmY(DateTime(2026, 3, 5)),
        '05/03/2026',
      );
      expect(
        AppFormatters.formatDateDmY(DateTime(2026, 12, 25)),
        '25/12/2026',
      );
    });

    test('formatVndCompact', () {
      expect(AppFormatters.formatVndCompact(double.nan), '0 đ');
      expect(AppFormatters.formatVndCompact(0), '0 đ');
      expect(AppFormatters.formatVndCompact(500), '500 đ');
      expect(AppFormatters.formatVndCompact(12500), '12.500 đ');
      expect(AppFormatters.formatVndCompact(999999), '999.999 đ');
      expect(AppFormatters.formatVndCompact(1000000), '1.00 tr đ');
      expect(AppFormatters.formatVndCompact(1550000), '1.55 tr đ');
    });
  });

  group('RssiDistanceHelper', () {
    test('platform calibration & validation', () {
      expect(RssiDistanceHelper.isIosPlatform(overrideIos: true), isTrue);
      expect(RssiDistanceHelper.isIosPlatform(overrideIos: false), isFalse);

      expect(RssiDistanceHelper.isValidRssi(0), isFalse);
      expect(RssiDistanceHelper.isValidRssi(127), isFalse);
      expect(RssiDistanceHelper.isValidRssi(-1), isTrue);
      expect(RssiDistanceHelper.isValidRssi(-115), isTrue);
      expect(RssiDistanceHelper.isValidRssi(-116), isFalse);

      expect(
        RssiDistanceHelper.defaultAutoLockThresholds(isIos: true),
        const [-72.0, -80.0, -88.0],
      );
      expect(
        RssiDistanceHelper.defaultAutoLockThresholds(isIos: false),
        const [-75.0, -83.0, -90.0],
      );
      expect(RssiDistanceHelper.defaultWalkUpThreshold(isIos: true), -62.0);
      expect(RssiDistanceHelper.defaultWalkUpThreshold(isIos: false), -55.0);

      expect(RssiDistanceHelper.normalizeRssiForBars(-70, isIos: true), -65);
      expect(RssiDistanceHelper.normalizeRssiForBars(-70, isIos: false), -70);
      expect(RssiDistanceHelper.normalizeRssiForLock(-80, isIos: true), -77.0);
      expect(RssiDistanceHelper.normalizeRssiForLock(-80, isIos: false), -80.0);
      expect(RssiDistanceHelper.normalizeRssiForNear(-58, isIos: true), -52.0);
      expect(RssiDistanceHelper.normalizeRssiForNear(-58, isIos: false), -58.0);
    });

    test('distance estimation and labels', () {
      expect(
        RssiDistanceHelper.estimateDistanceMeters(-59, isIos: false),
        closeTo(1.0, 0.001),
      );
      expect(
        RssiDistanceHelper.estimateDistanceMeters(-64, isIos: true),
        closeTo(1.0, 0.001),
      );
      expect(
        RssiDistanceHelper.estimateDistanceMeters(-30, isIos: false),
        0.5,
      );
      expect(
        RssiDistanceHelper.estimateDistanceMeters(-110, isIos: false),
        25.0,
      );

      expect(RssiDistanceHelper.lockDistanceLabel(-75, isIos: false), '3m');
      expect(RssiDistanceHelper.lockDistanceLabel(-79, isIos: true), '3m');
      expect(RssiDistanceHelper.lockDistanceLabel(-83, isIos: false), '5m');
      expect(RssiDistanceHelper.lockDistanceLabel(-89, isIos: false), '8m');
      expect(RssiDistanceHelper.lockDistanceLabel(-92, isIos: false), '10m');

      expect(RssiDistanceHelper.nearDistanceLabel(-48, isIos: false), '0.5m');
      expect(RssiDistanceHelper.nearDistanceLabel(-54, isIos: true), '0.5m');
      expect(RssiDistanceHelper.nearDistanceLabel(-52, isIos: false), '0.8m');
      expect(RssiDistanceHelper.nearDistanceLabel(-58, isIos: false), '1.5m');
      expect(RssiDistanceHelper.nearDistanceLabel(-65, isIos: false), '2.5m');
      expect(RssiDistanceHelper.nearDistanceLabel(-68, isIos: false), '3.5m');
    });
  });

  group('JsonPrefsStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('sanitizeKeyPart handles whitespace, special chars, and fallback', () {
      expect(JsonPrefsStore.sanitizeKeyPart(''), 'default_bike');
      expect(JsonPrefsStore.sanitizeKeyPart('   '), 'default_bike');
      expect(JsonPrefsStore.sanitizeKeyPart('///...'), 'default_bike');
      expect(
        JsonPrefsStore.sanitizeKeyPart('***', fallback: 'fallback_id'),
        'fallback_id',
      );
      expect(
        JsonPrefsStore.sanitizeKeyPart('  AA:BB:CC-12  '),
        'AA_BB_CC-12',
      );
    });

    test('readObject, writeObject, fallbackKeys, and decodeObject', () async {
      final store = _TestJsonStore();
      expect(store.tryDecode(''), isNull);
      expect(store.tryDecode('{invalid'), isNull);

      await store.save('legacy_key', const _TestRecord(id: 'old', count: 1));
      final fromFallback = await store.load(
        'primary_key',
        fallbackKeys: ['legacy_key'],
      );
      expect(fromFallback?.id, 'old');
      expect(fromFallback?.count, 1);

      await store.save('primary_key', const _TestRecord(id: 'new', count: 2));
      final fromPrimary = await store.load(
        'primary_key',
        fallbackKeys: ['legacy_key'],
      );
      expect(fromPrimary?.id, 'new');
      expect(fromPrimary?.count, 2);
    });

    test('readList distinguishes null (missing) from empty [] and filters', () async {
      final store = _TestJsonStore();
      expect(await store.loadAll('missing_list'), isNull);

      await store.saveAll('empty_list', const []);
      expect(await store.loadAll('empty_list'), isEmpty);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('corrupt_list', '{not_a_list');
      expect(await store.loadAll('corrupt_list'), isNull);

      await store.saveAll('items_list', const [
        _TestRecord(id: 'a', count: 1),
        _TestRecord(id: '', count: 2),
        _TestRecord(id: 'b', count: 3),
      ]);
      final filtered = await store.loadAll(
        'items_list',
        where: (e) => e.id.isNotEmpty,
      );
      expect(filtered?.map((e) => e.id).toList(), ['a', 'b']);

      await store.deleteAll(['items_list', 'empty_list']);
      expect(await store.loadAll('items_list'), isNull);
      expect(await store.loadAll('empty_list'), isNull);
    });
  });

  group('ProximityRssiTracker', () {
    test('ignores invalid RSSI and tracks staleness', () {
      final tracker = ProximityRssiTracker();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      expect(tracker.isStaleAt(t0), isTrue);
      expect(
        tracker.ingest(127, nearThreshold: -55, farThreshold: -83, now: t0),
        isNull,
      );
      expect(
        tracker.ingest(0, nearThreshold: -55, farThreshold: -83, now: t0),
        isNull,
      );
      expect(
        tracker.ingest(-116, nearThreshold: -55, farThreshold: -83, now: t0),
        isNull,
      );
      expect(tracker.smoothedRssi, isNull);
      expect(tracker.lastRssiAt, isNull);

      final first = tracker.ingest(
        -70,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0,
      );
      expect(first, -70.0);
      expect(tracker.isStaleAt(t0.add(const Duration(seconds: 4))), isFalse);
      expect(tracker.isStaleAt(t0.add(const Duration(seconds: 5))), isTrue);
    });

    test('rejects single strong spike and fast-tracks sustained approach', () {
      final tracker = ProximityRssiTracker();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      tracker.ingest(-80, nearThreshold: -55, farThreshold: -83, now: t0);

      // Single strong spike (-70 is +10 dB over -80, below nearThreshold -55)
      // should NOT jump directly; Kalman smooths it gently.
      final afterSpike = tracker.ingest(
        -70,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 1)),
      );
      expect(afterSpike, isNotNull);
      expect(afterSpike!, lessThan(-75.0));
      expect(tracker.approachStrongStreak, 1);

      // Next sample drops back to -80 -> streak resets, spike rejected.
      final afterDrop = tracker.ingest(
        -80,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 2)),
      );
      expect(afterDrop!, lessThan(-77.0));
      expect(tracker.approachStrongStreak, 0);

      // Two consecutive strong approach samples (>= +6 dB) trigger fast-track.
      tracker.ingest(
        -71,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 3)),
      );
      expect(tracker.approachStrongStreak, 1);

      final fastTracked = tracker.ingest(
        -68,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 4)),
      );
      expect(tracker.approachStrongStreak, 2);
      expect(fastTracked!, greaterThan(-72.0));
    });

    test('time-gap > 4s resets filter and pre-gap streaks cleanly', () {
      final tracker = ProximityRssiTracker();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      tracker.ingest(-54, nearThreshold: -55, farThreshold: -83, now: t0);
      expect(tracker.nearRawStreak, 1);

      // Gap > 4s resets pre-gap streak, then new near sample starts streak at 1.
      final afterGap = tracker.ingest(
        -53,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 6)),
      );
      expect(afterGap, -53.0);
      expect(tracker.nearRawStreak, 1);
      expect(tracker.farRawStreak, 0);
      expect(tracker.approachStrongStreak, 0);
    });

    test('far streak blends at 2 and snaps at 3, reset clears all state', () {
      final tracker = ProximityRssiTracker();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      tracker.ingest(-72, nearThreshold: -55, farThreshold: -83, now: t0);
      // 1st far sample
      tracker.ingest(
        -84,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 1)),
      );
      expect(tracker.farRawStreak, 1);

      // 2nd far sample with drop >= 6 dB -> blended (prev + cur) / 2
      final at2 = tracker.ingest(
        -86,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 2)),
      );
      expect(tracker.farRawStreak, 2);
      expect(at2!, lessThan(-78.0));

      // 3rd far sample -> snaps to curRssi
      final at3 = tracker.ingest(
        -88,
        nearThreshold: -55,
        farThreshold: -83,
        now: t0.add(const Duration(seconds: 3)),
      );
      expect(tracker.farRawStreak, 3);
      expect(at3, -88.0);

      tracker.reset();
      expect(tracker.smoothedRssi, isNull);
      expect(tracker.lastRssiAt, isNull);
      expect(tracker.nearRawStreak, 0);
      expect(tracker.farRawStreak, 0);
      expect(tracker.approachStrongStreak, 0);
      expect(tracker.kalman.currentEstimate, isNull);
    });
  });
}
