/// Login-Status der GP tom App (AIDL 1.29.0, IGPTomLoginChangedCallback).
/// Die Keys entsprechen den Enum-Namen aus der GPTom-AIDL-Bibliothek.
enum GpTomLoginStatus {
  userLoggedIn('USER_LOGGED_IN'),
  userLoggedOut('USER_LOGGED_OUT'),
  loginFailed('LOGIN_FAILED'),
  logoutFailed('LOGOUT_FAILED'),
  invalidCredentials('INVALID_CREDENTIALS'),
  invalidArgument('INVALID_ARGUMENT'),
  tidNotAssignedToThisUser('TID_NOT_ASSIGNED_TO_THIS_USER'),
  anotherTidUsedOnThisDevice('ANOTHER_TID_USED_ON_THIS_DEVICE'),
  tidAssignedAndLoggedIn('TID_ASSIGNED_AND_LOGGED_IN'),
  tidNotFound('TID_NOT_FOUND'),
  tidNotActive('TID_NOT_ACTIVE'),
  tidNotSelected('TID_NOT_SELECTED'),
  tidReleaseRequest('TID_RELEASE_REQUEST'),
  tidReleaseInvalidCode('TID_RELEASE_INVALID_CODE'),
  passwordChangeRequired('PASSWORD_CHANGE_REQUIRED'),
  passwordPendingConfirmation('PASSWORD_PENDING_CONFIRMATION'),
  passwordChanged('PASSWORD_CHANGED'),
  passwordChangeFailed('PASSWORD_CHANGE_FAILED'),
  unknown('UNKNOWN');

  final String key;

  const GpTomLoginStatus(this.key);

  static GpTomLoginStatus fromKey(String? key) {
    return values.where((e) => e.key == key).firstOrNull ?? unknown;
  }
}

/// Ein Login-Status-Update aus der GP tom App.
class GpTomLoginEvent {
  final GpTomLoginStatus status;

  /// Der unveränderte Status-String aus dem Callback (auch wenn er keinem
  /// bekannten [GpTomLoginStatus] entspricht).
  final String? rawStatus;
  final String? message;

  GpTomLoginEvent({
    required this.status,
    this.rawStatus,
    this.message,
  });

  bool get isLoggedIn =>
      status == GpTomLoginStatus.userLoggedIn ||
      status == GpTomLoginStatus.tidAssignedAndLoggedIn;

  @override
  String toString() =>
      'GpTomLoginEvent(status=$status, rawStatus=$rawStatus, message=$message)';
}
