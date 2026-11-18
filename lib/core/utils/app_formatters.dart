/// Bộ định dạng chuỗi dùng chung cho thời gian, quãng đường, ngày tháng và tiền tệ.
class AppFormatters {
  AppFormatters._();

  /// Định dạng [Duration] dạng đồng hồ `h:mm:ss` (nếu >= 1 giờ) hoặc `mm:ss`.
  static String formatDurationClock(Duration d) {
    final safe = d.isNegative ? Duration.zero : d;
    final h = safe.inHours;
    final m = safe.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = safe.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }

  /// Định dạng tổng số giây dạng đồng hồ `h:mm:ss` hoặc `mm:ss`; `<= 0` trả về `'00:00'`.
  static String formatDurationClockSec(int totalSec) {
    return formatDurationClock(
      totalSec <= 0 ? Duration.zero : Duration(seconds: totalSec),
    );
  }

  /// Định dạng thời lượng ngắn gọn kiểu thống kê (`'0 phút'`, `'2g 15p'`, `'12 phút'`, `'45 giây'`).
  static String formatDurationReadable(int totalSec) {
    if (totalSec <= 0) return '0 phút';
    final hours = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    if (hours > 0) {
      return mins > 0 ? '${hours}g ${mins}p' : '${hours}g';
    }
    if (mins > 0) return '$mins phút';
    return '$totalSec giây';
  }

  /// Định dạng thời lượng đầy đủ từng giây (`'0 giây'`, `'1 giờ 5 phút'`, `'3 phút 10 giây'`).
  static String formatDurationVerboseSec(int totalSec) {
    if (totalSec <= 0) return '0 giây';
    final hours = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    final secs = totalSec % 60;
    if (hours > 0) {
      return mins > 0 ? '$hours giờ $mins phút' : '$hours giờ';
    }
    if (mins > 0) {
      return secs > 0 ? '$mins phút $secs giây' : '$mins phút';
    }
    return '$secs giây';
  }

  /// Định dạng số km: làm tròn số nguyên nếu sát giá trị nguyên (`< 0.05`), ngược lại 1 chữ số thập phân.
  static String formatKm(double value) {
    if (!value.isFinite) return '0';
    final normalized = value.abs() < 0.05 ? 0.0 : value;
    if ((normalized - normalized.roundToDouble()).abs() < 0.05) {
      return normalized.round().toString();
    }
    return normalized.toStringAsFixed(1);
  }

  /// Định dạng ngày theo chuẩn `dd/MM/yyyy`.
  static String formatDateDmY(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    return '$d/$m/${date.year}';
  }

  /// Định dạng số tiền VNĐ gọn (`'1.25 tr đ'` khi `>= 1,000,000`, ngược lại phân cách hàng nghìn bằng `.`).
  static String formatVndCompact(double amount) {
    if (!amount.isFinite) return '0 đ';
    final rounded = amount.round();
    if (rounded >= 1000000) {
      final millions = rounded / 1000000.0;
      return '${millions.toStringAsFixed(2)} tr đ';
    }
    final isNegative = rounded < 0;
    final s = rounded.abs().toString();
    final buf = StringBuffer();
    if (isNegative) buf.write('-');
    for (int i = 0; i < s.length; i++) {
      final posFromEnd = s.length - i;
      if (i > 0 && posFromEnd % 3 == 0) {
        buf.write('.');
      }
      buf.write(s[i]);
    }
    return '${buf.toString()} đ';
  }
}
