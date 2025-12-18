import 'package:flutter/material.dart';
import '../models/item_model.dart';
import '../services/google_sheets_service.dart';
import '../config/sheets_config.dart';
import '../utils/date_utils.dart' as app_date_utils;

class AddItemScreen extends StatefulWidget {
  const AddItemScreen({super.key});

  @override
  State<AddItemScreen> createState() => _AddItemScreenState();
}

class _AddItemScreenState extends State<AddItemScreen> {
  final _formKey = GlobalKey<FormState>();
  final _employeeCompanyController = TextEditingController();
  final _companyNameController = TextEditingController();
  DateTime? _selectedLabourCardExpiry;
  DateTime? _selectedVisaExpiry;
  bool _isSaving = false;

  @override
  void dispose() {
    _employeeCompanyController.dispose();
    _companyNameController.dispose();
    super.dispose();
  }

  Future<void> _selectLabourCardExpiry(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedLabourCardExpiry ?? DateTime.now(),
      firstDate: DateTime.now().subtract(
        const Duration(days: 365 * 5),
      ), // Allow past dates
      lastDate: DateTime.now().add(const Duration(days: 365 * 10)), // 10 years
    );
    if (picked != null) {
      setState(() {
        _selectedLabourCardExpiry = picked;
      });
    }
  }

  Future<void> _selectVisaExpiry(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedVisaExpiry ?? DateTime.now(),
      firstDate: DateTime.now().subtract(
        const Duration(days: 365 * 5),
      ), // Allow past dates
      lastDate: DateTime.now().add(const Duration(days: 365 * 10)), // 10 years
    );
    if (picked != null) {
      setState(() {
        _selectedVisaExpiry = picked;
      });
    }
  }

  Future<void> _saveItem() async {
    // No validation needed - all fields are optional

    if (!SheetsConfig.isConfigured) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please configure Google Sheets in Settings first'),
          ),
        );
      }
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final sheetsService = GoogleSheetsService();
      if (!sheetsService.isInitialized) {
        final initialized = await sheetsService.initialize();
        if (!initialized) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Failed to initialize Google Sheets service'),
              ),
            );
          }
          setState(() {
            _isSaving = false;
          });
          return;
        }
      }

      // Get next auto-increment number
      final nextNumber = await sheetsService.getNextAutoIncrementNumber();

      // Normalize dates to midnight (date-only) to avoid time component issues
      DateTime? normalizedLabourCardExpiry;
      if (_selectedLabourCardExpiry != null) {
        normalizedLabourCardExpiry = DateTime(
          _selectedLabourCardExpiry!.year,
          _selectedLabourCardExpiry!.month,
          _selectedLabourCardExpiry!.day,
        );
      }

      DateTime? normalizedVisaExpiry;
      if (_selectedVisaExpiry != null) {
        normalizedVisaExpiry = DateTime(
          _selectedVisaExpiry!.year,
          _selectedVisaExpiry!.month,
          _selectedVisaExpiry!.day,
        );
      }

      final item = ItemModel(
        no: nextNumber.toString(),
        employeeCompany: _employeeCompanyController.text.trim().isEmpty
            ? null
            : _employeeCompanyController.text.trim(),
        companyName: _companyNameController.text.trim().isEmpty
            ? null
            : _companyNameController.text.trim(),
        labourCardExpiry: normalizedLabourCardExpiry,
        visaExpiry: normalizedVisaExpiry,
      );

      // Add item to Google Sheets
      await sheetsService.addItem(item);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Item added successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding item: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add New Item')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _employeeCompanyController,
              decoration: const InputDecoration(
                labelText: 'Employee',
                hintText: 'Enter employee name (optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _companyNameController,
              decoration: const InputDecoration(
                labelText: 'Company Name',
                hintText: 'Enter company name (optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.business),
              ),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () => _selectLabourCardExpiry(context),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Labour card expiry',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.calendar_today),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _selectedLabourCardExpiry != null
                          ? app_date_utils.DateUtils.formatDateDisplay(
                              _selectedLabourCardExpiry!,
                            )
                          : 'Select date (optional)',
                      style: TextStyle(
                        fontSize: 16,
                        color: _selectedLabourCardExpiry != null
                            ? null
                            : Colors.grey,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () => _selectVisaExpiry(context),
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Visa expiry',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.calendar_today),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _selectedVisaExpiry != null
                          ? app_date_utils.DateUtils.formatDateDisplay(
                              _selectedVisaExpiry!,
                            )
                          : 'Select date (optional)',
                      style: TextStyle(
                        fontSize: 16,
                        color: _selectedVisaExpiry != null ? null : Colors.grey,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isSaving ? null : _saveItem,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
              child: _isSaving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text('Save Item', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
