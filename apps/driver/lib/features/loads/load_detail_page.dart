import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/features/loads/driver_load_status.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:flutter/material.dart';

/// Driver execution UI for one already-authorized load. It cannot choose an
/// arbitrary state, driver, company, cancellation, reassignment or acceptance.
class LoadDetailPage extends StatefulWidget {
  const LoadDetailPage({
    required this.snapshot,
    this.captureAdapter,
    this.controller,
    super.key,
  });

  static const advanceButtonKey = Key('load-detail-advance-action');
  static const reportIncidentButtonKey = Key('load-detail-report-incident');
  static const incidentDescriptionFieldKey = Key(
    'load-detail-incident-description',
  );
  static const submitIncidentButtonKey = Key('load-detail-submit-incident');
  static const closeIncidentButtonKey = Key('load-detail-close-incident');

  static Key recordEvidenceButtonKey(DriverEvidenceType type) =>
      ValueKey<String>('load-detail-record-evidence-${type.wireValue}');

  final DriverLoadExecutionSnapshot snapshot;
  final DriverLocalEvidenceCaptureAdapter? captureAdapter;
  final DriverLoadStateController? controller;

  @override
  State<LoadDetailPage> createState() => _LoadDetailPageState();
}

class _LoadDetailPageState extends State<LoadDetailPage> {
  late final DriverLoadStateController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ?? DriverLoadStateController(widget.snapshot);
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  Future<void> _showIncidentForm() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _IncidentForm(controller: _controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final snapshot = _controller.snapshot;
        final strings = DriverStrings.of(context);
        final missingEvidence = _controller.missingRequiredDeliveryEvidence;
        final isBlocked = _controller.isDeliveryBlocked;
        final nextStatus = snapshot.serverDefinedNextStatus;
        final terminalStatus = _controller.terminalStatus;

        return Scaffold(
          appBar: AppBar(title: Text(strings.loadDetails)),
          body: SafeArea(
            child: FocusTraversalGroup(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final gutter = constraints.maxWidth >= 600 ? 24.0 : 16.0;
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 32),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _LoadHeader(
                              snapshot: snapshot,
                              statusOverride: terminalStatus,
                            ),
                            const SizedBox(height: 16),
                            _StopCard(
                              label: strings.pickup,
                              value: snapshot.pickupLabel,
                              icon: Icons.trip_origin_outlined,
                            ),
                            const SizedBox(height: 8),
                            _StopCard(
                              label: strings.delivery,
                              value: snapshot.deliveryLabel,
                              icon: Icons.location_on_outlined,
                            ),
                            const SizedBox(height: 24),
                            if (terminalStatus != null)
                              _TerminalLoadPanel(status: terminalStatus)
                            else ...<Widget>[
                              _EvidencePanel(
                                evidence: snapshot.recordedEvidence,
                                missingEvidence: missingEvidence,
                                controller: _controller,
                                captureAdapter: widget.captureAdapter,
                              ),
                              if (isBlocked) ...<Widget>[
                                const SizedBox(height: 16),
                                _BlockedDeliveryPanel(
                                  missingEvidence: missingEvidence,
                                ),
                              ],
                              const SizedBox(height: 24),
                              if (nextStatus != null)
                                _NextStepAction(
                                  nextStatus: nextStatus,
                                  isBlocked: isBlocked,
                                  isAdvancing: _controller.isAdvancing,
                                  isPendingSync: _controller.isActionQueued,
                                  onAdvance: _controller.advanceServerDefinedStep,
                                )
                              else
                                _NoFurtherStep(),
                              if (_controller.failure != null) ...<Widget>[
                                const SizedBox(height: 16),
                                _ExecutionFeedback(
                                  message: strings.executionFailure(
                                    _controller.failure!,
                                  ),
                                  icon: Icons.info_outline,
                                ),
                              ],
                              if (_controller.queuedAction != null) ...<Widget>[
                                const SizedBox(height: 16),
                                _ExecutionFeedback(
                                  message: strings.actionQueued,
                                  icon: Icons.schedule_send_outlined,
                                  positive: true,
                                ),
                              ],
                              if (_controller.queuedIncident != null) ...<Widget>[
                                const SizedBox(height: 16),
                                _ExecutionFeedback(
                                  message: strings.incidentQueued,
                                  icon: Icons.schedule_send_outlined,
                                  positive: true,
                                ),
                              ],
                              const SizedBox(height: 24),
                              SizedBox(
                                height: 48,
                              child: OutlinedButton.icon(
                                key: LoadDetailPage.reportIncidentButtonKey,
                                onPressed: _controller.queuedIncident == null
                                    ? _showIncidentForm
                                    : null,
                                  icon: const Icon(Icons.report_problem_outlined),
                                  label: Text(strings.reportProblem),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LoadHeader extends StatelessWidget {
  const _LoadHeader({required this.snapshot, this.statusOverride});

  final DriverLoadExecutionSnapshot snapshot;
  final DriverLoadOperationalStatus? statusOverride;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              snapshot.loadNumber,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Semantics(
              label: strings.loadStatusSemantics(
                strings.operationalStatus(
                  statusOverride ?? snapshot.operationalStatus,
                ),
              ),
              child: Text.rich(
                TextSpan(
                  style: Theme.of(context).textTheme.bodyLarge,
                  children: <InlineSpan>[
                    TextSpan(
                      text: '${strings.status}: ',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: strings.operationalStatus(
                        statusOverride ?? snapshot.operationalStatus,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalLoadPanel extends StatelessWidget {
  const _TerminalLoadPanel({required this.status});

  final DriverLoadOperationalStatus status;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    return Semantics(
      liveRegion: true,
      label: strings.terminalLoadConfirmation(status),
      child: Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              const ExcludeSemantics(child: Icon(Icons.task_alt_outlined)),
              const SizedBox(width: 12),
              Expanded(child: Text(strings.terminalLoadConfirmation(status))),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopCard extends StatelessWidget {
  const _StopCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ExcludeSemantics(child: Icon(icon)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(value, style: Theme.of(context).textTheme.bodyLarge),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EvidencePanel extends StatelessWidget {
  const _EvidencePanel({
    required this.evidence,
    required this.missingEvidence,
    required this.controller,
    required this.captureAdapter,
  });

  final List<DriverEvidenceCapture> evidence;
  final List<DriverEvidenceType> missingEvidence;
  final DriverLoadStateController controller;
  final DriverLocalEvidenceCaptureAdapter? captureAdapter;

  Future<void> _recordEvidence(DriverEvidenceType type) async {
    final adapter = captureAdapter;
    if (adapter == null) {
      controller.reportLocalCaptureUnavailable();
      return;
    }
    try {
      final capture = await adapter.capturePrivateEvidence(type);
      if (capture != null) {
        await controller.recordEvidence(capture);
      }
    } on Object {
      controller.reportLocalCaptureUnavailable();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              strings.evidence,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(strings.evidenceRecordedLocally),
            const SizedBox(height: 12),
            if (evidence.isEmpty)
              Text(strings.noEvidenceRecorded)
            else
              ...evidence.map(
                (capture) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: <Widget>[
                      const ExcludeSemantics(
                        child: Icon(Icons.task_alt_outlined),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(strings.evidenceType(capture.type))),
                    ],
                  ),
                ),
              ),
            if (missingEvidence.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(strings.privateEvidenceCaptureNotice),
              const SizedBox(height: 12),
              Text(
                missingEvidence.map(strings.evidenceType).join(', '),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (captureAdapter == null) ...<Widget>[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(strings.privateEvidenceCaptureUnavailable),
                ),
              ],
              const SizedBox(height: 12),
              ...missingEvidence.map(
                (type) {
                  final queued = controller.queuedEvidenceFor(type);
                  final typeLabel = strings.evidenceType(type);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            key: LoadDetailPage.recordEvidenceButtonKey(type),
                            onPressed:
                                controller.isEvidenceActionBusy(type) ||
                                    captureAdapter == null
                                ? null
                                : () => _recordEvidence(type),
                            icon: controller.isRecordingEvidenceFor(type)
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.attach_file_outlined),
                            label: Text(
                              strings.recordEvidenceLocally(typeLabel),
                            ),
                          ),
                        ),
                        if (queued != null) ...<Widget>[
                          const SizedBox(height: 8),
                          _ExecutionFeedback(
                            message: strings.evidenceQueued(typeLabel),
                            icon: Icons.schedule_send_outlined,
                            positive: true,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BlockedDeliveryPanel extends StatelessWidget {
  const _BlockedDeliveryPanel({required this.missingEvidence});

  final List<DriverEvidenceType> missingEvidence;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    return Semantics(
      liveRegion: true,
      label: '${strings.deliveryBlocked}. ${strings.missingEvidenceDetail}',
      child: Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const ExcludeSemantics(
                    child: Icon(Icons.assignment_late_outlined),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      strings.deliveryBlocked,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(strings.missingEvidenceDetail),
              const SizedBox(height: 8),
              ...missingEvidence.map(
                (type) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(strings.evidenceType(type)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NextStepAction extends StatelessWidget {
  const _NextStepAction({
    required this.nextStatus,
    required this.isBlocked,
    required this.isAdvancing,
    required this.isPendingSync,
    required this.onAdvance,
  });

  final DriverLoadOperationalStatus nextStatus;
  final bool isBlocked;
  final bool isAdvancing;
  final bool isPendingSync;
  final Future<void> Function() onAdvance;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    final label = strings.advanceTo(strings.operationalStatus(nextStatus));
    return Semantics(
      label: '${strings.nextStep}: $label',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(strings.nextStep, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              key: LoadDetailPage.advanceButtonKey,
              onPressed: isBlocked || isAdvancing || isPendingSync
                  ? null
                  : () => onAdvance(),
              icon: isAdvancing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
              label: Text(label),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoFurtherStep extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    return Semantics(
      liveRegion: true,
      child: _ExecutionFeedback(
        message: strings.noFurtherDriverStep,
        icon: Icons.info_outline,
      ),
    );
  }
}

class _ExecutionFeedback extends StatelessWidget {
  const _ExecutionFeedback({
    required this.message,
    required this.icon,
    this.positive = false,
  });

  final String message;
  final IconData icon;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: message,
      liveRegion: true,
      child: Card(
        color: positive ? colors.primaryContainer : colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ExcludeSemantics(child: Icon(icon)),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}

class _IncidentForm extends StatefulWidget {
  const _IncidentForm({required this.controller});

  final DriverLoadStateController controller;

  @override
  State<_IncidentForm> createState() => _IncidentFormState();
}

class _IncidentFormState extends State<_IncidentForm> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  var _type = DriverIncidentType.pickupIssue;
  var _isSubmitting = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isSubmitting = true);
    await widget.controller.reportIncident(
      type: _type,
      description: _descriptionController.text,
    );
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (widget.controller.queuedIncident != null) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, bottomInset + 24),
        child: FocusTraversalGroup(
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          strings.incidentFormTitle,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      SizedBox(
                        height: 48,
                        child: TextButton(
                          key: LoadDetailPage.closeIncidentButtonKey,
                          onPressed: _isSubmitting
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: Text(strings.close),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<DriverIncidentType>(
                    initialValue: _type,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: strings.incidentCategory,
                    ),
                    items: DriverIncidentType.values
                        .map(
                          (type) => DropdownMenuItem<DriverIncidentType>(
                            value: type,
                            child: Text(strings.incidentType(type)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isSubmitting
                        ? null
                        : (value) {
                            if (value != null) setState(() => _type = value);
                          },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: LoadDetailPage.incidentDescriptionFieldKey,
                    controller: _descriptionController,
                    minLines: 3,
                    maxLines: 6,
                    maxLength: 2000,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      labelText: strings.incidentDescription,
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? strings.incidentDescriptionRequired
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Text(strings.incidentLocationWhenAvailable),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      key: LoadDetailPage.submitIncidentButtonKey,
                      onPressed: _isSubmitting ? null : _submit,
                      child: _isSubmitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(strings.submitIncident),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
