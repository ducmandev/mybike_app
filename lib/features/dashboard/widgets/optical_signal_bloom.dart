import 'package:flutter/material.dart';

/// Hiệu ứng vết ánh sáng tỏa ra của xi-nhan cam đỏ ấm áp (Optical Ambient Light Bloom)
/// - Cải tiến vệt loang mềm mại, không bị cứng hay lộ viền hộp chữ nhật.
/// - Áp dụng gradient đa tầng (luminous rim guide + smooth exponential diffuse).
/// - Nhịp thở quang học êm ái, bám sát góc bo tròn của taplo xe.
class OpticalSignalBloom extends StatefulWidget {
  final bool isLeft;
  final bool isRight;
  final Widget child;
  final double borderRadius;

  const OpticalSignalBloom({
    super.key,
    required this.isLeft,
    required this.isRight,
    required this.child,
    this.borderRadius = 22.0,
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
      duration: const Duration(milliseconds: 700),
    );
    // Nhịp thở tự nhiên: bừng sáng êm ái và tan mờ mềm mại
    _pulseAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: Curves.easeInOutCubic,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Stack(
        clipBehavior: Clip.antiAlias,
        children: [
          widget.child,

          // Vết ánh sáng tỏa ra bên trái (Soft Amber-Orange Diffuse Bloom)
          if (widget.isLeft)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, _) {
                    return Opacity(
                      opacity: _pulseAnim.value,
                      child: Row(
                        children: [
                          // 1. Dải viền phát quang quang học (Luminous Optical Rim Guide)
                          Container(
                            width: 3.5,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Color(0x99F97316),
                                  Color(0xEEFB923C),
                                  Color(0x99F97316),
                                  Colors.transparent,
                                ],
                                stops: [0.0, 0.25, 0.5, 0.75, 1.0],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x66F97316),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),

                          // 2. Vệt loang mềm mại lan dần vào tâm không viền cắt
                          Expanded(
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: [
                                    Color(0x52FB923C), // Hổ phách ấm sáng tại viền
                                    Color(0x35F97316), // Cam Dat Bike chuyển tiếp
                                    Color(0x18F97316), // Tan mờ êm
                                    Color(0x06FB7185), // Ánh đào nhẹ
                                    Colors.transparent, // Trong suốt hoàn toàn
                                  ],
                                  stops: [0.0, 0.18, 0.40, 0.70, 1.0],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),

          // Vết ánh sáng tỏa ra bên phải (Soft Amber-Orange Diffuse Bloom)
          if (widget.isRight)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, _) {
                    return Opacity(
                      opacity: _pulseAnim.value,
                      child: Row(
                        children: [
                          // Vệt loang mềm mại lan dần từ tâm sang phải
                          Expanded(
                            child: Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: [
                                    Colors.transparent,
                                    Color(0x06FB7185),
                                    Color(0x18F97316),
                                    Color(0x35F97316),
                                    Color(0x52FB923C),
                                  ],
                                  stops: [0.0, 0.30, 0.60, 0.82, 1.0],
                                ),
                              ),
                            ),
                          ),

                          // Dải viền phát quang quang học bên phải
                          Container(
                            width: 3.5,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Color(0x99F97316),
                                  Color(0xEEFB923C),
                                  Color(0x99F97316),
                                  Colors.transparent,
                                ],
                                stops: [0.0, 0.25, 0.5, 0.75, 1.0],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x66F97316),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
