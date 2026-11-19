import 'package:flutter/foundation.dart';

import 'package:example/core/data/product_repository.dart';
import 'package:example/core/models/product.dart';
import '../data/realtime_connection.dart';

/// Page-scoped: 1:1 with the detail view. Injects the page's
/// [RealtimeConnection] (the same instance, via DI) alongside the repository.
class ProductDetailViewModel extends ChangeNotifier {
  ProductDetailViewModel(this._repo, this._connection);

  final ProductRepository _repo;
  final RealtimeConnection _connection;

  bool loading = true;
  Product? product;

  /// The product after this one, wrapping around; set once loaded.
  late String nextId;

  bool get connected => _connection.isOpen;

  Future<void> load(String id) async {
    product = await _repo.getById(id);
    final products = await _repo.getProducts();
    final index = products.indexWhere((p) => p.id == id);
    nextId = products[(index + 1) % products.length].id;
    loading = false;
    notifyListeners();
  }
}
