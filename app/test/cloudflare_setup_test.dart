import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/cloudflare_setup.dart';

void main() {
  test('apex domain gets an rsq hostname', () {
    final plan = planDomain('Lumono.site');
    expect(plan, isNotNull);
    expect(plan!.hostname, 'rsq.lumono.site');
    expect(plan.zoneNames, ['lumono.site']);
  });

  test('full hostname keeps its name and walks zones', () {
    final plan = planDomain('https://vpn.example.com/');
    expect(plan!.hostname, 'vpn.example.com');
    expect(plan.zoneNames, ['vpn.example.com', 'example.com']);
  });

  test('rejects empty and single labels', () {
    expect(planDomain(''), isNull);
    expect(planDomain('localhost'), isNull);
    expect(planDomain('https://'), isNull);
  });

  test('each hostname gets its own worker name', () {
    expect(workerScriptName('mafcss.lumono.site'), 'tiaotiaohou-mafcss-lumono-site');
    expect(workerScriptName('rsq.example.com'), isNot(workerScriptName('vpn.example.com')));
    expect(workerScriptName('MAFCSS.Lumono.site'), workerScriptName('mafcss.lumono.site'));
  });
}
