import 'package:flutter_test/flutter_test.dart';
import 'package:rsq/diagnostics.dart';

void main() {
  test('sums worker requests from graphql', () {
    final total = sumWorkerRequests({
      'data': {
        'viewer': {
          'accounts': [
            {
              'workersInvocationsAdaptive': [
                {'sum': {'requests': 1200}},
                {'sum': {'requests': 30}},
              ],
            },
          ],
        },
      },
    });
    expect(total, 1230);
    expect(sumWorkerRequests({'errors': []}), isNull);
  });
}
