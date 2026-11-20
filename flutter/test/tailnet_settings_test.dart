import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _SettingsBinding extends Fake implements RustdeskImpl {
  @override
  String translate(
          {required String name, required String locale, dynamic hint}) =>
      name;

  @override
  String mainGetOptionSync({required String key, dynamic hint}) =>
      key == kOptionStopService ? 'Y' : '';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      switch (invocation.memberName) {
        #isIncomingOnly ||
        #isOutgoingOnly ||
        #isDisableSettings ||
        #mainIsInstalled ||
        #mainHasHwcodec ||
        #mainHasVram ||
        #mainIsOptionFixed ||
        #mainGetUseTextureRender ||
        #mainCurrentIsWayland ||
        #mainAudioSupportLoopback ||
        #mainIsLoginWayland =>
          false,
        #isDisableAccount || #isCustomClient => true,
        #mainGetBuildinOption ||
        #mainGetLocalOption ||
        #mainVideoSaveDirectory =>
          '',
        #mainGetCommon => Future.value('true'),
        #mainGetLangs => Future.value('[]'),
        #mainGetSoundInputs => Future.value(<String>[]),
        #mainGetOption => Future.value(''),
        #mainHandleWaylandScreencastRestoreToken => Future.value(''),
        #mainSupportRemoveWallpaper => Future.value(false),
        _ => super.noSuchMethod(invocation),
      };
}

void main() {
  testWidgets('General shows the local service state without a home page',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    platformFFI.setBindingForTesting(_SettingsBinding());
    await tester.pumpWidget(MaterialApp(
      theme: MyTheme.lightTheme,
      home: DesktopSettingPage(initialTabkey: SettingsTabKey.general),
    ));

    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('Service'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
