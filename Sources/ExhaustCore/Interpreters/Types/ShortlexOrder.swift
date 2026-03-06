//
//  ShortlexOrder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

/// Lightweight three-way comparison result without Foundation dependency.
public enum ShortlexOrder: Equatable, Hashable {
    case lt, eq, gt
}
