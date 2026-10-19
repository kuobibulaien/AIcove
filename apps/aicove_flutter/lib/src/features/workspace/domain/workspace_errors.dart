/// A workspace operation the caller can fix; [message] goes back to the
/// agent as the tool result.
class WorkspaceException implements Exception {
  const WorkspaceException(this.code, this.message);

  const WorkspaceException.invalidPath(this.message) : code = 'invalid_path';
  const WorkspaceException.notFound(this.message) : code = 'not_found';
  const WorkspaceException.revisionMismatch(this.message)
    : code = 'revision_mismatch';
  const WorkspaceException.busy(this.message) : code = 'busy';
  const WorkspaceException.limit(this.message) : code = 'limit';
  const WorkspaceException.readOnly(this.message) : code = 'read_only';
  const WorkspaceException.unauthorized(this.message) : code = 'unauthorized';

  final String code;
  final String message;

  @override
  String toString() => 'WorkspaceException($code): $message';
}
