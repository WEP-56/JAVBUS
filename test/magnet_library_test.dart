import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:javbus/src/magnets/magnet_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('upsert can add and update favorites from an empty library', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'javbus_magnet_library_test_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final MagnetLibrary library = MagnetLibrary(storageRoot: temp);

    await library.upsert(
      newStoredMagnet(
        id: 'magnet_TEST',
        title: 'First title',
        magnet: 'magnet:?xt=urn:btih:TEST',
      ),
    );
    await library.upsert(
      newStoredMagnet(
        id: 'magnet_TEST',
        title: 'Updated title',
        magnet: 'magnet:?xt=urn:btih:TEST',
      ),
    );

    final List<StoredFavorite> items = await library.load();
    expect(
      items.where((StoredFavorite item) => item.id == 'magnet_TEST'),
      hasLength(1),
    );
    expect(
      items.firstWhere((StoredFavorite item) => item.id == 'magnet_TEST').title,
      'Updated title',
    );

    await library.delete('magnet_TEST');
    expect(
      (await library.load()).where(
        (StoredFavorite item) => item.id == 'magnet_TEST',
      ),
      isEmpty,
    );
  });
}
