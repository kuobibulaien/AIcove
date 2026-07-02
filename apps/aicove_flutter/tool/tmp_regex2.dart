void main() {
  final s1 = '...    A';
  final s2 = '...\u00A0\u00A0\u00A0A';
  final s3 = '...　　　A';
  final s4 = '...\t\t\tA';

  final p = RegExp(r'((?:\.+)+)(?:[^\S\r\n]+)(?=[A-Za-z])');
  print('s1=' + p.hasMatch(s1).toString());
  print('s2=' + p.hasMatch(s2).toString());
  print('s3=' + p.hasMatch(s3).toString());
  print('s4=' + p.hasMatch(s4).toString());
}
