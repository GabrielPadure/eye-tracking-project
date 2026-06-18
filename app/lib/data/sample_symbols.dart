import 'package:flutter/material.dart';
import '../models/aac_symbol.dart';

/// Catalog of predefined AAC symbols the user can pick from when configuring
/// their board. Six of these are shown at a time on the 3 × 2 board (see
/// [BoardProvider]).
///
/// Order is stable — `defaultSelectedIds` references entries by id, and the
/// editor UI lists symbols in catalog order.
const List<AacSymbol> symbolCatalog = [
  // Responses
  AacSymbol(id: 'yes',     label: 'Yes',       category: 'Responses', color: Color(0xFF4CAF50)),
  AacSymbol(id: 'no',      label: 'No',        category: 'Responses', color: Color(0xFFF44336)),
  // Needs
  AacSymbol(id: 'eat',     label: 'Eat',       category: 'Needs',     color: Color(0xFF2196F3)),
  AacSymbol(id: 'drink',   label: 'Drink',     category: 'Needs',     color: Color(0xFF03A9F4)),
  AacSymbol(id: 'toilet',  label: 'Toilet',    category: 'Needs',     color: Color(0xFF9C27B0)),
  AacSymbol(id: 'help',    label: 'Help',      category: 'Needs',     color: Color(0xFFFF5722)),
  // Feelings
  AacSymbol(id: 'happy',   label: 'Happy',     category: 'Feelings',  color: Color(0xFFFFEB3B)),
  AacSymbol(id: 'sad',     label: 'Sad',       category: 'Feelings',  color: Color(0xFF3F51B5)),
  AacSymbol(id: 'pain',    label: 'Pain',      category: 'Feelings',  color: Color(0xFFE91E63)),
  AacSymbol(id: 'tired',   label: 'Tired',     category: 'Feelings',  color: Color(0xFF607D8B)),
  // Actions
  AacSymbol(id: 'play',    label: 'Play',      category: 'Actions',   color: Color(0xFFFF9800)),
  AacSymbol(id: 'stop',    label: 'Stop',      category: 'Actions',   color: Color(0xFFB71C1C)),
  AacSymbol(id: 'more',    label: 'More',      category: 'Actions',   color: Color(0xFF8BC34A)),
  AacSymbol(id: 'done',    label: 'Done',      category: 'Actions',   color: Color(0xFF009688)),
  // Social
  AacSymbol(id: 'hello',   label: 'Hello',     category: 'Social',    color: Color(0xFFFFC107)),
  AacSymbol(id: 'thanks',  label: 'Thank you', category: 'Social',    color: Color(0xFFCDDC39)),
];

/// Six symbol ids shown by default on a fresh install (one per grid slot).
const List<String> defaultSelectedIds = [
  'yes', 'no', 'eat',
  'drink', 'help', 'play',
];
