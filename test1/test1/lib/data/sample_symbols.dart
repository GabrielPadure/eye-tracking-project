import 'package:flutter/material.dart';
import '../models/aac_symbol.dart';

/// 15 placeholder AAC symbols used while real Cboard assets are not yet
/// integrated. Replace [color] placeholders with [imagePath] values pointing
/// to Cboard symbol images when the asset pipeline is ready.
const List<AacSymbol> sampleSymbols = [
  AacSymbol(id: '1', label: 'Yes',   category: 'Responses', color: Color(0xFF4CAF50)),
  AacSymbol(id: '2', label: 'No',    category: 'Responses', color: Color(0xFFF44336)),
  AacSymbol(id: '3', label: 'Play',  category: 'Needs',     color: Color(0xFFFF9800)),
  AacSymbol(id: '4', label: 'Eat',  category: 'Actions',   color: Color(0xFF2196F3)),
];
