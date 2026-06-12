enum TransactionType {
  sell(1, 'Sell'),
  voidSell(2, 'Void'),
  closeBatch(4, 'Close Batch');

  final int id;
  final String text;

  const TransactionType(this.id, this.text);
}