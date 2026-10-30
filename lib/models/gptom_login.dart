import 'gptom_info.dart';

/// Zugangsdaten, die die Kasse hereinreicht. Das Plugin speichert sie nicht.
/// `toString()` verrät weder Benutzer noch Passwort.
class GptomCredentials {
  final String _username;
  final String _password;
  final String _terminalId;

  const GptomCredentials({
    required String username,
    required String password,
    required String terminalId,
  })  : _username = username,
        _password = password,
        _terminalId = terminalId;

  /// E-Mail des GP-tom-Benutzers, ohne Leerzeichen am Rand.
  String get username => _username.trim();

  /// Passwort unverändert (Leerzeichen können Teil des Passworts sein).
  String get password => _password;

  /// Terminal-ID (TID), ohne Leerzeichen am Rand.
  String get terminalId => _terminalId.trim();

  @override
  String toString() => 'GptomCredentials(terminalId: $terminalId)';
}

/// Anmeldezustand der GP tom App.
enum GptomLoginState {
  loggedIn,
  loggedOut,

  /// Ohne Internet, zwischengespeicherter Stand (Android, AIDL 1.29).
  unverifiedLoggedIn,
  unknown;

  /// Android: `logInStatus` aus `App2AppInfoResponse`. Fehlt er, entscheidet
  /// das ältere Feld `isLoggedIn`.
  static GptomLoginState fromAndroid(String? logInStatus, {Object? isLoggedIn}) {
    switch (logInStatus) {
      case 'LOGGED_IN':
        return loggedIn;
      case 'LOGGED_OUT':
        return loggedOut;
      case 'UNVERIFIED_LOGGED_IN':
        return unverifiedLoggedIn;
    }
    if (logInStatus == null) {
      if (isLoggedIn == true) return loggedIn;
      if (isLoggedIn == false) return loggedOut;
    }
    return unknown;
  }
}

/// Ausgang einer Login-, Logout- oder Passwort-Operation.
enum GptomLoginOutcome {
  /// USER_LOGGED_IN, TID_ASSIGNED_AND_LOGGED_IN, iOS COMPLETED
  loggedIn,

  /// ensureLoggedIn: war schon angemeldet (passende TID)
  alreadyLoggedIn,

  /// USER_LOGGED_OUT, iOS logout COMPLETED
  loggedOut,

  /// Android TID_RELEASE_REQUEST: Code kommt per Mail, login(authCode:) erneut
  tidReleaseRequired,

  /// iOS tidAlreadyOccupied: kein API-Weg, manuell freigeben
  tidOccupied,
  passwordChangeRequired,

  /// Mail-Code verschickt, changePassword(code:) erneut
  passwordPendingConfirmation,
  passwordChanged,
  invalidCredentials,

  /// TID_RELEASE_INVALID_CODE / invalidCode
  invalidCode,
  tidNotAssignedToUser,
  anotherTidOnDevice,
  tidNotFound,
  tidNotActive,
  tidNotSelected,

  /// INVALID_ARGUMENT / invalidUserName
  invalidArgument,
  terminalSetupFailed,

  /// ensureLoggedIn: angemeldet, aber mit anderer TID
  otherTerminal,

  /// UNVERIFIED_LOGGED_IN (kein Login-Versuch) / iOS networkError
  offline,

  /// ensureLoggedIn: die Kasse hat keine Zugangsdaten geliefert
  noCredentials,
  notInstalled,

  /// Android: Signatur der GP tom App passt nicht
  untrustedApp,

  /// Login-/Info-Service fehlt (GP tom zu alt)
  notSupported,

  /// iOS: gptom:// ließ sich nicht öffnen
  cannotOpen,

  /// iOS CANCELLED
  cancelled,
  timeout,

  /// Es läuft schon eine Login-Operation.
  busy,

  /// LOGIN_FAILED, LOGOUT_FAILED, PASSWORD_CHANGE_FAILED, failed, userNotLoggedIn
  failed,

  /// Unbekannter Status, der rohe Wert bleibt in [GptomLoginResult] erhalten.
  unknown,
}

/// Welche Konto-Operation gerade läuft.
enum GptomAccountOperation { login, logout, changePassword }

/// Ergebnis einer Login-, Logout- oder Passwort-Operation.
class GptomLoginResult {
  final GptomLoginOutcome outcome;

  /// Android-Status bzw. iOS-`status`.
  final String? rawStatus;

  /// iOS-`error`.
  final String? rawError;

  /// Android-`message`, nie mit Zugangsdaten.
  final String? message;

  /// Bei ensureLoggedIn der zuletzt gelesene Status.
  final GpTomInfo? info;

  const GptomLoginResult({
    required this.outcome,
    this.rawStatus,
    this.rawError,
    this.message,
    this.info,
  });

  bool get isLoggedIn =>
      outcome == GptomLoginOutcome.loggedIn ||
      outcome == GptomLoginOutcome.alreadyLoggedIn;

  /// Die Kasse muss einen Code (Mail) abfragen und erneut aufrufen.
  bool get needsCode =>
      outcome == GptomLoginOutcome.tidReleaseRequired ||
      outcome == GptomLoginOutcome.passwordPendingConfirmation ||
      outcome == GptomLoginOutcome.invalidCode;

  GptomLoginResult withInfo(GpTomInfo? info) => GptomLoginResult(
        outcome: outcome,
        rawStatus: rawStatus,
        rawError: rawError,
        message: message,
        info: info,
      );

  /// Bewusst ohne `message` und `info`.
  @override
  String toString() => 'GptomLoginResult(outcome: ${outcome.name}, '
      'rawStatus: $rawStatus, rawError: $rawError)';
}

/// Android: Status aus `onLoginStatusChanged` auf den Ausgang abbilden.
GptomLoginOutcome outcomeFromAndroidStatus(String? status) {
  switch (status) {
    case 'USER_LOGGED_IN':
    case 'TID_ASSIGNED_AND_LOGGED_IN':
      return GptomLoginOutcome.loggedIn;
    case 'USER_LOGGED_OUT':
      return GptomLoginOutcome.loggedOut;
    case 'LOGIN_FAILED':
    case 'LOGOUT_FAILED':
    case 'PASSWORD_CHANGE_FAILED':
      return GptomLoginOutcome.failed;
    case 'INVALID_CREDENTIALS':
      return GptomLoginOutcome.invalidCredentials;
    case 'INVALID_ARGUMENT':
      return GptomLoginOutcome.invalidArgument;
    case 'TID_NOT_ASSIGNED_TO_THIS_USER':
      return GptomLoginOutcome.tidNotAssignedToUser;
    case 'ANOTHER_TID_USED_ON_THIS_DEVICE':
      return GptomLoginOutcome.anotherTidOnDevice;
    case 'TID_NOT_FOUND':
      return GptomLoginOutcome.tidNotFound;
    case 'TID_NOT_ACTIVE':
      return GptomLoginOutcome.tidNotActive;
    case 'TID_NOT_SELECTED':
      return GptomLoginOutcome.tidNotSelected;
    case 'TID_RELEASE_REQUEST':
      return GptomLoginOutcome.tidReleaseRequired;
    case 'TID_RELEASE_INVALID_CODE':
      return GptomLoginOutcome.invalidCode;
    case 'PASSWORD_CHANGE_REQUIRED':
      return GptomLoginOutcome.passwordChangeRequired;
    case 'PASSWORD_PENDING_CONFIRMATION':
      return GptomLoginOutcome.passwordPendingConfirmation;
    case 'PASSWORD_CHANGED':
      return GptomLoginOutcome.passwordChanged;
    default:
      return GptomLoginOutcome.unknown;
  }
}

const _loginIgnoriert = {
  'USER_LOGGED_OUT',
  'LOGOUT_FAILED',
  'PASSWORD_PENDING_CONFIRMATION',
  'PASSWORD_CHANGED',
  'PASSWORD_CHANGE_FAILED',
};

const _logoutStatus = {'USER_LOGGED_OUT', 'LOGOUT_FAILED'};

const _passwortStatus = {
  'PASSWORD_PENDING_CONFIRMATION',
  'PASSWORD_CHANGED',
  'PASSWORD_CHANGE_FAILED',
  'INVALID_ARGUMENT',
  'INVALID_CREDENTIALS',
};

/// Beendet dieser Android-Status die wartende Operation? Login nimmt alles
/// außer den Status der anderen Operationen, auch unbekannte Werte.
bool androidStatusBeendet(GptomAccountOperation op, String? status) {
  if (status == null) return false;
  switch (op) {
    case GptomAccountOperation.login:
      return !_loginIgnoriert.contains(status);
    case GptomAccountOperation.logout:
      return _logoutStatus.contains(status);
    case GptomAccountOperation.changePassword:
      return _passwortStatus.contains(status);
  }
}

/// iOS: `status` und `error` des Redirects auf den Ausgang abbilden.
/// [codeGesendet]: der Passwortwechsel lief schon mit Mail-Code (zweite Stufe).
GptomLoginOutcome outcomeFromIosRedirect({
  required GptomAccountOperation op,
  required String? status,
  required String? error,
  bool codeGesendet = false,
}) {
  switch (status?.toUpperCase()) {
    case 'CANCELLED':
    case 'CANCELED':
      return GptomLoginOutcome.cancelled;
    case 'COMPLETED':
      switch (op) {
        case GptomAccountOperation.login:
          return GptomLoginOutcome.loggedIn;
        case GptomAccountOperation.logout:
          return GptomLoginOutcome.loggedOut;
        case GptomAccountOperation.changePassword:
          return codeGesendet
              ? GptomLoginOutcome.passwordChanged
              : GptomLoginOutcome.passwordPendingConfirmation;
      }
    case 'ERROR':
      switch (error) {
        case 'invalidCredentials':
          return GptomLoginOutcome.invalidCredentials;
        case 'tidNotAssignedToThisUser':
          return GptomLoginOutcome.tidNotAssignedToUser;
        case 'tidAlreadyOccupied':
          return GptomLoginOutcome.tidOccupied;
        case 'anotherTidUsedOnThisDevice':
          return GptomLoginOutcome.anotherTidOnDevice;
        case 'passwordChangeRequired':
          return GptomLoginOutcome.passwordChangeRequired;
        case 'passwordPendingConfirmation':
          return GptomLoginOutcome.passwordPendingConfirmation;
        case 'invalidCode':
          return GptomLoginOutcome.invalidCode;
        case 'invalidUserName':
          return GptomLoginOutcome.invalidArgument;
        case 'terminalSetupFailed':
          return GptomLoginOutcome.terminalSetupFailed;
        case 'networkError':
          return GptomLoginOutcome.offline;
        case null:
        case 'userNotLoggedIn':
        case 'failed':
          return GptomLoginOutcome.failed;
        default:
          return GptomLoginOutcome.unknown;
      }
    default:
      return GptomLoginOutcome.unknown;
  }
}
