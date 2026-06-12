import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/cancel_mode.dart';
import 'package:gptom_aidl_plugin/enums/preferable_receipt_type.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';

void main() {
  group('TransactionType', () {
    test('IDs entsprechen der GPTom-API', () {
      expect(TransactionType.sell.id, 1);
      expect(TransactionType.voidSell.id, 2);
      expect(TransactionType.refund.id, 3);
      expect(TransactionType.closeBatch.id, 4);
    });

    test('fromId mappt über die ID', () {
      expect(TransactionType.fromId(1), TransactionType.sell);
      expect(TransactionType.fromId(2), TransactionType.voidSell);
      expect(TransactionType.fromId(3), TransactionType.refund);
      expect(TransactionType.fromId(4), TransactionType.closeBatch);
      expect(TransactionType.fromId(4.0), TransactionType.closeBatch);
      expect(TransactionType.fromId(99), isNull);
      expect(TransactionType.fromId(null), isNull);
      expect(TransactionType.fromId('1'), isNull);
    });
  });

  group('CancelMode', () {
    test('IDs entsprechen der GPTom-API', () {
      expect(CancelMode.last.id, 1);
      expect(CancelMode.older.id, 2);
    });
  });

  group('TransactionMethode', () {
    test('Werte entsprechen der GPTom-API', () {
      expect(TransactionMethode.card.text, 'CARD');
      expect(TransactionMethode.cash.text, 'CASH');
    });
  });

  group('PreferableReceiptType', () {
    test('Keys entsprechen der GPTom-API und bleiben unverändert', () {
      // Diese Werte (inkl. der deutschen Begriffe) kommen so aus der
      // GPTom-API-Doku – nicht "vereinheitlichen" oder übersetzen.
      expect(PreferableReceiptType.telephone.key, 'TELEFON');
      expect(PreferableReceiptType.email.key, 'E-MAIL');
      expect(PreferableReceiptType.qr.key, 'QR');
      expect(PreferableReceiptType.print.key, 'DRUCKEN');
    });
  });

  group('GpTomLoginStatus', () {
    test('fromKey mappt die AIDL-Statuswerte', () {
      expect(GpTomLoginStatus.fromKey('USER_LOGGED_IN'), GpTomLoginStatus.userLoggedIn);
      expect(GpTomLoginStatus.fromKey('INVALID_CREDENTIALS'), GpTomLoginStatus.invalidCredentials);
      expect(GpTomLoginStatus.fromKey('PASSWORD_CHANGED'), GpTomLoginStatus.passwordChanged);
      expect(GpTomLoginStatus.fromKey('TID_NOT_FOUND'), GpTomLoginStatus.tidNotFound);
    });

    test('unbekannte Werte werden unknown', () {
      expect(GpTomLoginStatus.fromKey('SOMETHING_NEW'), GpTomLoginStatus.unknown);
      expect(GpTomLoginStatus.fromKey(null), GpTomLoginStatus.unknown);
    });

    test('isLoggedIn-Helfer', () {
      expect(
        GpTomLoginEvent(status: GpTomLoginStatus.userLoggedIn).isLoggedIn,
        isTrue,
      );
      expect(
        GpTomLoginEvent(status: GpTomLoginStatus.tidAssignedAndLoggedIn).isLoggedIn,
        isTrue,
      );
      expect(
        GpTomLoginEvent(status: GpTomLoginStatus.userLoggedOut).isLoggedIn,
        isFalse,
      );
    });
  });
}
