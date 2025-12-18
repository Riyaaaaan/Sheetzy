import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/excel_import_service.dart';
import '../config/sheets_config.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final ExcelImportService _importService = ExcelImportService();
  bool _isImporting = false;
  ImportResult? _importResult;
  String? _selectedFileName;

  Future<void> _pickAndImportFile() async {
    if (!SheetsConfig.isConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please configure Google Sheets in Settings first'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    setState(() {
      _isImporting = true;
      _importResult = null;
      _selectedFileName = null;
    });

    try {
      // Pick Excel file
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() {
          _isImporting = false;
        });
        return;
      }

      final file = result.files.first;
      setState(() {
        _selectedFileName = file.name;
      });

      print('[ImportScreen] File selected: ${file.name}');
      print('[ImportScreen] File path: ${file.path}');
      print(
        '[ImportScreen] File bytes: ${file.bytes != null ? file.bytes!.length : "null"}',
      );

      // Read file bytes - try bytes first, then path
      Uint8List? fileBytes = file.bytes;

      if (fileBytes == null && file.path != null) {
        print('[ImportScreen] Reading file from path: ${file.path}');
        try {
          final fileData = File(file.path!);
          fileBytes = await fileData.readAsBytes();
          print('[ImportScreen] Read ${fileBytes.length} bytes from file path');
        } catch (e) {
          print('[ImportScreen] Error reading file from path: $e');
          throw Exception('Could not read file: $e');
        }
      }

      if (fileBytes == null) {
        throw Exception(
          'Could not read file bytes. File bytes and path are both null.',
        );
      }

      print(
        '[ImportScreen] Starting Excel import with ${fileBytes.length} bytes',
      );

      // Import Excel file
      final importResult = await _importService.importExcelFile(fileBytes);

      print(
        '[ImportScreen] Import completed. Success: ${importResult.success}',
      );
      if (!importResult.success) {
        print('[ImportScreen] Import error: ${importResult.error}');
      } else {
        print(
          '[ImportScreen] Imported: ${importResult.companiesImported} companies, ${importResult.employeesImported} employees',
        );
      }

      setState(() {
        _importResult = importResult;
        _isImporting = false;
      });

      // Show result message
      if (mounted) {
        String message;
        if (importResult.success) {
          // Build success message
          final parts = <String>[];
          if (importResult.companiesImported > 0) {
            parts.add('${importResult.companiesImported} company(ies)');
          }
          if (importResult.employeesImported > 0) {
            parts.add('${importResult.employeesImported} employee(s)');
          }
          if (parts.isEmpty) {
            message = 'Import completed but no items were imported';
          } else {
            message = 'Successfully imported ${parts.join(' and ')}';
            if (importResult.failedCount > 0) {
              message += ' (${importResult.failedCount} failed)';
            }
          }
        } else {
          message = importResult.error ?? 'Import failed';
        }

        final color = importResult.success ? Colors.green : Colors.red;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: color,
            duration: Duration(seconds: importResult.success ? 3 : 5),
          ),
        );

        // If successful, pop and refresh after a short delay
        if (importResult.success) {
          await Future.delayed(const Duration(seconds: 1));
          if (mounted) {
            Navigator.pop(
              context,
              true,
            ); // Return true to indicate refresh needed
          }
        }
      }
    } catch (e, stackTrace) {
      print('[ImportScreen] Exception during import: $e');
      print('[ImportScreen] Stack trace: $stackTrace');

      setState(() {
        _isImporting = false;
        _importResult = ImportResult(success: false, error: 'Error: $e');
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error importing file: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Excel'),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Instructions
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3B82F6).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.info_outline,
                            color: Color(0xFF3B82F6),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Text(
                            'Import Excel File',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Select an Excel file (.xlsx) to import. The app will automatically:',
                      style: TextStyle(fontSize: 14, color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 12),
                    _buildBulletPoint('Detect company and employee sections'),
                    _buildBulletPoint(
                      'Map columns with similar names to app fields',
                    ),
                    _buildBulletPoint(
                      'Ignore calculated fields like "days left"',
                    ),
                    _buildBulletPoint('Parse dates in various formats'),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Import button
              ElevatedButton.icon(
                onPressed: _isImporting ? null : _pickAndImportFile,
                icon: _isImporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      )
                    : const Icon(Icons.upload_file),
                label: Text(
                  _isImporting ? 'Importing...' : 'Select Excel File',
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: const Color(0xFF3B82F6),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              // Selected file name
              if (_selectedFileName != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.description, color: Color(0xFF64748B)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _selectedFileName!,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFF1E293B),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // Import result
              if (_importResult != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _importResult!.success
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _importResult!.success
                          ? Colors.green.shade200
                          : Colors.red.shade200,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _importResult!.success
                                ? Icons.check_circle
                                : Icons.error,
                            color: _importResult!.success
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _importResult!.success
                                  ? 'Import Completed'
                                  : 'Import Failed',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: _importResult!.success
                                    ? Colors.green.shade900
                                    : Colors.red.shade900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_importResult!.success) ...[
                        if (_importResult!.companiesImported > 0)
                          _buildResultRow(
                            'Companies',
                            _importResult!.companiesImported.toString(),
                            Colors.blue,
                          ),
                        if (_importResult!.employeesImported > 0)
                          _buildResultRow(
                            'Employees',
                            _importResult!.employeesImported.toString(),
                            Colors.purple,
                          ),
                        if (_importResult!.failedCount > 0)
                          _buildResultRow(
                            'Failed',
                            _importResult!.failedCount.toString(),
                            Colors.orange,
                          ),
                      ] else ...[
                        Text(
                          _importResult!.error ?? 'Unknown error',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.red.shade900,
                          ),
                        ),
                      ],
                      // Show errors if any
                      if (_importResult!.errors.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Divider(),
                        const SizedBox(height: 8),
                        const Text(
                          'Errors:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._importResult!.errors
                            .take(5)
                            .map(
                              (error) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  '• $error',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.red,
                                  ),
                                ),
                              ),
                            ),
                        if (_importResult!.errors.length > 5)
                          Text(
                            '... and ${_importResult!.errors.length - 5} more',
                            style: const TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: Colors.red,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBulletPoint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '• ',
            style: TextStyle(fontSize: 14, color: Color(0xFF64748B)),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14, color: Color(0xFF64748B)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: Color(0xFF64748B)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


