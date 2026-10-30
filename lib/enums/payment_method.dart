/// Zahlungsart für GP tom (nur Android, AIDL-Feld `paymentMethod`).
///
/// Die Werte entsprechen dem `PaymentMethod`-Enum der AIDL-Bibliothek; Gson
/// verwirft unbekannte Schreibweisen stillschweigend.
enum GptomPaymentMethod {
  card('CARD'),
  cash('CASH'),
  accountPayment('ACCOUNT_PAYMENT'),
  paymentGateway('PAYMENT_GATEWAY'),
  blik('BLIK_PAYMENT'),
  goCrypto('GO_CRYPTO');

  /// Wert für das app2app-JSON (AIDL, Android).
  final String aidlKey;

  const GptomPaymentMethod(this.aidlKey);
}
