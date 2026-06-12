enum TransactionMethode {
  card('CARD'),
  cash('CASH');

  final String text;

  const TransactionMethode(this.text);
}