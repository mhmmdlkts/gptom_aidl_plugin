import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/models/gptom_login.dart';

void main() {
  group('outcomeFromAndroidStatus', () {
    final tabelle = <String?, GptomLoginOutcome>{
      'USER_LOGGED_IN': GptomLoginOutcome.loggedIn,
      'TID_ASSIGNED_AND_LOGGED_IN': GptomLoginOutcome.loggedIn,
      'USER_LOGGED_OUT': GptomLoginOutcome.loggedOut,
      'LOGIN_FAILED': GptomLoginOutcome.failed,
      'LOGOUT_FAILED': GptomLoginOutcome.failed,
      'PASSWORD_CHANGE_FAILED': GptomLoginOutcome.failed,
      'INVALID_CREDENTIALS': GptomLoginOutcome.invalidCredentials,
      'INVALID_ARGUMENT': GptomLoginOutcome.invalidArgument,
      'TID_NOT_ASSIGNED_TO_THIS_USER': GptomLoginOutcome.tidNotAssignedToUser,
      'ANOTHER_TID_USED_ON_THIS_DEVICE': GptomLoginOutcome.anotherTidOnDevice,
      'TID_NOT_FOUND': GptomLoginOutcome.tidNotFound,
      'TID_NOT_ACTIVE': GptomLoginOutcome.tidNotActive,
      'TID_NOT_SELECTED': GptomLoginOutcome.tidNotSelected,
      'TID_RELEASE_REQUEST': GptomLoginOutcome.tidReleaseRequired,
      'TID_RELEASE_INVALID_CODE': GptomLoginOutcome.invalidCode,
      'PASSWORD_CHANGE_REQUIRED': GptomLoginOutcome.passwordChangeRequired,
      'PASSWORD_PENDING_CONFIRMATION':
          GptomLoginOutcome.passwordPendingConfirmation,
      'PASSWORD_CHANGED': GptomLoginOutcome.passwordChanged,
      'NEU_IN_ZUKUNFT': GptomLoginOutcome.unknown,
      null: GptomLoginOutcome.unknown,
    };
    tabelle.forEach((status, erwartet) {
      test('$status -> $erwartet', () {
        expect(outcomeFromAndroidStatus(status), erwartet);
      });
    });
  });

  group('androidStatusBeendet', () {
    test('login ignoriert Status anderer Operationen und null', () {
      for (final s in [
        'USER_LOGGED_OUT',
        'LOGOUT_FAILED',
        'PASSWORD_PENDING_CONFIRMATION',
        'PASSWORD_CHANGED',
        'PASSWORD_CHANGE_FAILED',
        null,
      ]) {
        expect(androidStatusBeendet(GptomAccountOperation.login, s), isFalse,
            reason: '$s');
      }
    });

    test('login beendet bei Login-Ausgängen und unbekannten Werten', () {
      expect(
          androidStatusBeendet(
              GptomAccountOperation.login, 'TID_RELEASE_REQUEST'),
          isTrue);
      expect(
          androidStatusBeendet(GptomAccountOperation.login, 'USER_LOGGED_IN'),
          isTrue);
      expect(
          androidStatusBeendet(GptomAccountOperation.login, 'NEU_IN_ZUKUNFT'),
          isTrue);
    });

    test('logout nur bei USER_LOGGED_OUT und LOGOUT_FAILED', () {
      const op = GptomAccountOperation.logout;
      expect(androidStatusBeendet(op, 'USER_LOGGED_OUT'), isTrue);
      expect(androidStatusBeendet(op, 'LOGOUT_FAILED'), isTrue);
      expect(androidStatusBeendet(op, 'USER_LOGGED_IN'), isFalse);
      expect(androidStatusBeendet(op, 'NEU_IN_ZUKUNFT'), isFalse);
      expect(androidStatusBeendet(op, null), isFalse);
    });

    test('changePassword nur bei den fünf Passwort-Werten', () {
      const op = GptomAccountOperation.changePassword;
      for (final s in [
        'PASSWORD_PENDING_CONFIRMATION',
        'PASSWORD_CHANGED',
        'PASSWORD_CHANGE_FAILED',
        'INVALID_ARGUMENT',
        'INVALID_CREDENTIALS',
      ]) {
        expect(androidStatusBeendet(op, s), isTrue, reason: s);
      }
      expect(androidStatusBeendet(op, 'USER_LOGGED_IN'), isFalse);
      expect(androidStatusBeendet(op, 'USER_LOGGED_OUT'), isFalse);
      expect(androidStatusBeendet(op, 'NEU_IN_ZUKUNFT'), isFalse);
      expect(androidStatusBeendet(op, null), isFalse);
    });
  });

  group('outcomeFromIosRedirect', () {
    GptomLoginOutcome o(GptomAccountOperation op, String? status,
            [String? error, bool code = false]) =>
        outcomeFromIosRedirect(
            op: op, status: status, error: error, codeGesendet: code);

    test('CANCELLED/CANCELED ohne Groß-/Kleinschreibung', () {
      for (final s in ['CANCELLED', 'CANCELED', 'cancelled', 'Canceled']) {
        expect(o(GptomAccountOperation.login, s), GptomLoginOutcome.cancelled);
      }
    });

    test('COMPLETED je Operation', () {
      expect(o(GptomAccountOperation.login, 'COMPLETED'),
          GptomLoginOutcome.loggedIn);
      expect(o(GptomAccountOperation.logout, 'COMPLETED'),
          GptomLoginOutcome.loggedOut);
      expect(o(GptomAccountOperation.changePassword, 'COMPLETED'),
          GptomLoginOutcome.passwordPendingConfirmation);
      expect(o(GptomAccountOperation.changePassword, 'COMPLETED', null, true),
          GptomLoginOutcome.passwordChanged);
    });

    test('ERROR mit error', () {
      final tabelle = <String?, GptomLoginOutcome>{
        'invalidCredentials': GptomLoginOutcome.invalidCredentials,
        'tidNotAssignedToThisUser': GptomLoginOutcome.tidNotAssignedToUser,
        'tidAlreadyOccupied': GptomLoginOutcome.tidOccupied,
        'anotherTidUsedOnThisDevice': GptomLoginOutcome.anotherTidOnDevice,
        'passwordChangeRequired': GptomLoginOutcome.passwordChangeRequired,
        'passwordPendingConfirmation':
            GptomLoginOutcome.passwordPendingConfirmation,
        'invalidCode': GptomLoginOutcome.invalidCode,
        'invalidUserName': GptomLoginOutcome.invalidArgument,
        'terminalSetupFailed': GptomLoginOutcome.terminalSetupFailed,
        'networkError': GptomLoginOutcome.offline,
        'userNotLoggedIn': GptomLoginOutcome.failed,
        'failed': GptomLoginOutcome.failed,
        null: GptomLoginOutcome.failed,
        'etwasNeues': GptomLoginOutcome.unknown,
      };
      tabelle.forEach((error, erwartet) {
        expect(o(GptomAccountOperation.login, 'ERROR', error), erwartet,
            reason: '$error');
      });
    });

    test('anderer oder fehlender status -> unknown', () {
      expect(o(GptomAccountOperation.login, 'WAS_ANDERES'),
          GptomLoginOutcome.unknown);
      expect(o(GptomAccountOperation.login, null), GptomLoginOutcome.unknown);
    });
  });

  group('GptomCredentials', () {
    final c = GptomCredentials(
      username: ' livia@melisse-nails.example ',
      password: ' Geheim 1+2&3%#ä ',
      terminalId: ' 12345678 ',
    );

    test('trimmt Benutzer und TID, Passwort bleibt unverändert', () {
      expect(c.username, 'livia@melisse-nails.example');
      expect(c.terminalId, '12345678');
      expect(c.password, ' Geheim 1+2&3%#ä ');
    });

    test('toString verrät weder Passwort noch Benutzer', () {
      final s = c.toString();
      expect(s, 'GptomCredentials(terminalId: 12345678)');
      expect(s, isNot(contains('Geheim')));
      expect(s, isNot(contains('livia')));
    });
  });

  group('GptomLoginResult', () {
    test('isLoggedIn', () {
      for (final o in GptomLoginOutcome.values) {
        final erwartet = o == GptomLoginOutcome.loggedIn ||
            o == GptomLoginOutcome.alreadyLoggedIn;
        expect(GptomLoginResult(outcome: o).isLoggedIn, erwartet, reason: '$o');
      }
    });

    test('needsCode', () {
      for (final o in GptomLoginOutcome.values) {
        final erwartet = o == GptomLoginOutcome.tidReleaseRequired ||
            o == GptomLoginOutcome.passwordPendingConfirmation ||
            o == GptomLoginOutcome.invalidCode;
        expect(GptomLoginResult(outcome: o).needsCode, erwartet, reason: '$o');
      }
    });

    test('toString enthält keine Nachricht', () {
      final r = GptomLoginResult(
          outcome: GptomLoginOutcome.failed,
          rawStatus: 'ERROR',
          rawError: 'failed',
          message: 'geheim');
      expect(r.toString(), isNot(contains('geheim')));
      expect(r.toString(), contains('failed'));
    });
  });

  group('GptomLoginState.fromAndroid', () {
    test('direkte Werte und Rückfall auf isLoggedIn', () {
      expect(GptomLoginState.fromAndroid('LOGGED_IN'), GptomLoginState.loggedIn);
      expect(GptomLoginState.fromAndroid('LOGGED_OUT'),
          GptomLoginState.loggedOut);
      expect(GptomLoginState.fromAndroid('UNVERIFIED_LOGGED_IN'),
          GptomLoginState.unverifiedLoggedIn);
      expect(GptomLoginState.fromAndroid(null, isLoggedIn: true),
          GptomLoginState.loggedIn);
      expect(GptomLoginState.fromAndroid(null, isLoggedIn: false),
          GptomLoginState.loggedOut);
      expect(GptomLoginState.fromAndroid(null), GptomLoginState.unknown);
    });
  });
}
