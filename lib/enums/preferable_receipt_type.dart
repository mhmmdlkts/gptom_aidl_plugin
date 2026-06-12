enum PreferableReceiptType {
  telephone('TELEFON'),
  email('E-MAIL'),
  qr('QR'),
  print('DRUCKEN');

  final String key;

  const PreferableReceiptType(this.key);
}