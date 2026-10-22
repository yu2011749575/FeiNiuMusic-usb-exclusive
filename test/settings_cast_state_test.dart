import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_cast_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DlnaCastSettings.resetForTest();
  });

  test('默认关闭投屏', () async {
    await DlnaCastSettings.ensureLoaded();
    expect(DlnaCastSettings.enabled.value, isFalse);
  });

  test('setEnabled 持久化并更新状态', () async {
    await DlnaCastSettings.ensureLoaded();
    await DlnaCastSettings.setEnabled(false);
    expect(DlnaCastSettings.enabled.value, isFalse);

    // 重新加载（模拟重启）应读到持久化的关闭值
    DlnaCastSettings.resetForTest();
    await DlnaCastSettings.ensureLoaded();
    expect(DlnaCastSettings.enabled.value, isFalse);

    await DlnaCastSettings.setEnabled(true);
    expect(DlnaCastSettings.enabled.value, isTrue);
  });
}
