enum TransactionType {
  sell(1, 'Sell'),
  voidSell(2, 'Void'),
  refund(3, 'Refund'),
  closeBatch(4, 'Close Batch');

  final int id;
  final String text;

  const TransactionType(this.id, this.text);

  /// Mappt die GPTom-ID (1=SALE, 2=VOID, 3=REFUND, 4=CLOSE_BATCH) auf das Enum.
  static TransactionType? fromId(Object? id) {
    if (id is! num) return null;
    final intId = id.toInt();
    return values.where((e) => e.id == intId).firstOrNull;
  }
}
