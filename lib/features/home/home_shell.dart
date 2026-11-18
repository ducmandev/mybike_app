// Shell chính — 3 Tabs Chuẩn Ngôn Ngữ Thiết Kế Xe Máy Điện Dat Bike:
// [ Xe ] · [ Năng Lượng ] · [ Chủ Xe ]

import 'package:flutter/material.dart';

import '../../ui/app_theme.dart';
import '../../ui/geely_icons.dart';
import '../charging/charging_screen.dart';
import '../profile/profile_screen.dart';
import 'my_bike_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: IndexedStack(
        index: _tab.clamp(0, 2),
        children: const [
          MyBikeScreen(),
          ChargingScreen(),
          ProfileScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: const Border(top: BorderSide(color: AppColors.panelBorder, width: 1)),
          boxShadow: [
            BoxShadow(
              color: AppColors.textPrimary.withValues(alpha: 0.025),
              blurRadius: 12,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          height: 64,
          backgroundColor: Colors.transparent,
          indicatorColor: AppColors.primary.withValues(alpha: 0.08),
          indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (s) => AppTypography.labelSm(
              color: s.contains(WidgetState.selected) ? AppColors.primary : AppColors.textDim,
              fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            ).copyWith(letterSpacing: 0.1),
          ),
          destinations: [
            NavigationDestination(
              icon: GeelyIcons.bike(size: 22, color: AppColors.textDim),
              selectedIcon: GeelyIcons.bike(size: 22, color: AppColors.primary),
              label: 'Xe',
            ),
            NavigationDestination(
              icon: GeelyIcons.charging(size: 22, color: AppColors.textDim),
              selectedIcon: GeelyIcons.charging(size: 22, color: AppColors.primary),
              label: 'Năng Lượng',
            ),
            NavigationDestination(
              icon: GeelyIcons.profile(size: 22, color: AppColors.textDim),
              selectedIcon: GeelyIcons.profile(size: 22, color: AppColors.primary),
              label: 'Chủ Xe',
            ),
          ],
        ),
      ),
    );
  }
}
