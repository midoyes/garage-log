import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/repository.dart';
import 'fuel_form.dart';
import 'maintenance_form.dart';
import 'plans_page.dart';
import 'vehicle_form.dart';

void _push(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

void openFuelForm(BuildContext context, Vehicle vehicle, {FuelLog? log}) =>
    _push(context, FuelFormPage(vehicle: vehicle, log: log));

void openMaintenanceForm(
  BuildContext context,
  Vehicle vehicle, {
  MaintenanceWithItems? existing,
}) =>
    _push(context, MaintenanceFormPage(vehicle: vehicle, existing: existing));

void openVehicleForm(BuildContext context, {Vehicle? vehicle}) =>
    _push(context, VehicleFormPage(vehicle: vehicle));

void openPlans(BuildContext context) => _push(context, const PlansPage());

void openPartHistory(BuildContext context, String name) =>
    _push(context, PartHistoryPage(name: name));
