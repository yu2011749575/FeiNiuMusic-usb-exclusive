import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_onboarding_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 重置静态懒加载缓存与值，避免跨 test 污染
    AppOnboardingSettings.resetForTest();
  });

  test('默认未完成引导（completed == false）', () async {
    await AppOnboardingSettings.ensureLoaded();
    expect(AppOnboardingSettings.completed.value, false);
  });

  test('已标记完成后加载为 true', () async {
    SharedPreferences.setMockInitialValues({'app_onboarding_completed': true});
    await AppOnboardingSettings.ensureLoaded();
    expect(AppOnboardingSettings.completed.value, true);
  });

  test('setCompleted 更新 notifier 并持久化', () async {
    await AppOnboardingSettings.ensureLoaded();
    expect(AppOnboardingSettings.completed.value, false);

    await AppOnboardingSettings.setCompleted();
    expect(AppOnboardingSettings.completed.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('app_onboarding_completed'), true);
  });
}
