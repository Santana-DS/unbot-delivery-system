class Restaurant {
  final String id;
  final String name;
  final String emoji;
  final String bgColor;
  final double rating;
  final int etaMinutes;
  final List<Product> products;

  const Restaurant({
    required this.id,
    required this.name,
    required this.emoji,
    required this.bgColor,
    required this.rating,
    required this.etaMinutes,
    required this.products,
  });
}

class Product {
  final String id;
  final String name;
  final String description;
  final String emoji;
  final double price;
  int quantity;

  Product({
    required this.id,
    required this.name,
    required this.description,
    required this.emoji,
    required this.price,
    this.quantity = 0,
  });
}

class Order {
  final String id;
  final String restaurantName;
  final List<OrderItem> items;
  final String address;
  final double total;
  final OrderStatus status;

  const Order({
    required this.id,
    required this.restaurantName,
    required this.items,
    required this.address,
    required this.total,
    required this.status,
  });
}

class OrderItem {
  final String name;
  final int quantity;
  final double price;

  const OrderItem({
    required this.name,
    required this.quantity,
    required this.price,
  });
}

enum OrderStatus { pending, preparing, onTheWay, delivered }

extension OrderStatusExt on OrderStatus {
  String get label {
    switch (this) {
      case OrderStatus.pending:
        return 'Pendente';
      case OrderStatus.preparing:
        return 'Em preparo';
      case OrderStatus.onTheWay:
        return 'A caminho';
      case OrderStatus.delivered:
        return 'Entregue';
    }
  }
}

// Sample data
final sampleRestaurants = [
  Restaurant(
    id: '1',
    name: 'Marmitas da Vó',
    emoji: '🍱',
    bgColor: 'FFF3EE',
    rating: 4.8,
    etaMinutes: 12,
    products: [
      Product(
        id: 'p1',
        name: 'Marmita Executiva',
        description: 'Frango grelhado, arroz, feijão, salada',
        emoji: '🍱',
        price: 18.0,
      ),
      Product(
        id: 'p2',
        name: 'Marmita Vegana',
        description: 'Legumes grelhados, arroz integral, grão de bico',
        emoji: '🥗',
        price: 20.0,
      ),
      Product(
        id: 'p3',
        name: 'Marmita Especial',
        description: 'Bife grelhado, purê, farofa, arroz e feijão',
        emoji: '🍖',
        price: 24.0,
      ),
    ],
  ),
  Restaurant(
    id: '2',
    name: 'Fit & Fresh',
    emoji: '🥗',
    bgColor: 'EDFCF8',
    rating: 4.6,
    etaMinutes: 18,
    products: [
      Product(
        id: 'p4',
        name: 'Bowl Fitness',
        description: 'Quinoa, legumes, peito de peru, molho',
        emoji: '🥗',
        price: 22.0,
      ),
      Product(
        id: 'p5',
        name: 'Salada Caesar',
        description: 'Frango, croutons, parmesão, molho caesar',
        emoji: '🥙',
        price: 19.0,
      ),
    ],
  ),
  Restaurant(
    id: '3',
    name: 'Pasta & Co.',
    emoji: '🍝',
    bgColor: 'F0F4FF',
    rating: 4.9,
    etaMinutes: 22,
    products: [
      Product(
        id: 'p6',
        name: 'Massa ao Molho',
        description: 'Espaguete, molho pomodoro, parmesão',
        emoji: '🍝',
        price: 20.0,
      ),
      Product(
        id: 'p7',
        name: 'Carbonara',
        description: 'Espaguete, bacon, ovos, parmesão',
        emoji: '🍜',
        price: 23.0,
      ),
    ],
  ),
  Restaurant(
    id: '4',
    name: 'Frango Grelhado',
    emoji: '🍗',
    bgColor: 'FFF8EE',
    rating: 4.7,
    etaMinutes: 15,
    products: [
      Product(
        id: 'p8',
        name: 'Meio Frango',
        description: 'Frango grelhado temperado, acompanhamentos',
        emoji: '🍗',
        price: 28.0,
      ),
    ],
  ),
];

final sampleOrders = [
  const Order(
    id: '4821',
    restaurantName: 'Marmitas da Vó',
    items: [OrderItem(name: 'Marmita Executiva', quantity: 1, price: 18)],
    address: 'Faculdade de Tecnologia, FT - UnB',
    total: 18.0,
    status: OrderStatus.onTheWay,
  ),
  const Order(
    id: '4820',
    restaurantName: 'Marmitas da Vó',
    items: [
      OrderItem(name: 'Bowl Fitness', quantity: 2, price: 22),
      OrderItem(name: 'Marmita Executiva', quantity: 1, price: 18),
    ],
    address: 'SQS 108 Bloco D',
    total: 62.0,
    status: OrderStatus.delivered,
  ),
  const Order(
    id: '4819',
    restaurantName: 'Pasta & Co.',
    items: [OrderItem(name: 'Massa ao Molho', quantity: 1, price: 20)],
    address: 'Rua Ipê, 88',
    total: 20.0,
    status: OrderStatus.pending,
  ),
];
