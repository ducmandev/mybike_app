import 'package:flutter/material.dart';

/// Hiệu ứng vết ánh sáng tỏa ra của xi-nhan cam đỏ nhẹ (Optical Ambient Light Bloom)
/// Không hiển thị nút bấm hay logo nào ở trạng thái chờ.
/// Khi bật xi-nhan trái/phải, tỏa ra một vùng ánh sáng cam hổ phách pha đỏ đào nhẹ mềm mại.
class OpticalSignalBloom extends StatefulWidget {
  final bool isLeft;
  final bool isRight;
  final Widget child;

  const OpticalSignalBloom({
    super.key,
    required this.isLeft,
    required this.isRight,
    required this.child,
  });

  @override
  State<OpticalSignalBloom> createState() => _OpticalSignalBloomState();
}

class _OpticalSignalBloomState extends State<OpticalSignalBloom>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _pulseAnim = Tween<double>(begin: 0.15, end: 1.0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: Curves.easeInOutSine,
      ),
    );

    if (widget.isLeft || widget.isRight) {
      _animController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant OpticalSignalBloom oldWidget) {
    super.didUpdateWidget(oldWidget);
    final isActive = widget.isLeft || widget.isRight;
    final wasActive = oldWidget.isLeft || oldWidget.isRight;

    if (isActive && !wasActive) {
      _animController.repeat(reverse: true);
    } else if (!isActive && wasActive) {
      _animController.stop();
      _animController.reset();
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.antiAlias,
      children: [
        widget.child,

        // Vết ánh sáng tỏa ra bên trái (Amber-Red Bloom)
        if (widget.isLeft)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 140,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (context, _) {
                  return Opacity(
                    opacity: _pulseAnim.value,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(-1.0, 0.0),
                          radius: 1.15,
                          colors: [
                            Color(0x99FB923C), // Cam hổ phách sáng
                            Color(0x66F97316), // Cam Dat Bike
                            Color(0x33EF4444), // Đỏ đào nhẹ
                            Color(0x00F97316), // Tan mờ hoàn toàn
                          ],
                          stops: [0.0, 0.35, 0.65, 1.0],
                        ),
                      ),
                      child: SizedBox.expand(),
                    ),
                  );
                },
              ),
            ),
          ),

        // Vết ánh sáng tỏa ra bên phải (Amber-Red Bloom)
        if (widget.isRight)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 140,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (context, _) {
                  return Opacity(
                    opacity: _pulseAnim.value,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(1.0, 0.0),
                          radius: 1.15,
                          colors: [
                            Color(0x99FB923C),
                            Color(0x66F97316),
                            Color(0x33EF4444),
                            Color(0x00F97316),
                          ],
                          stops: [0.0, 0.35, 0.65, 1.0],
                        ),
                      ),
                      child: SizedBox.expand(),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
