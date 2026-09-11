// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"

namespace interface
{
	// How a voxel's definition is found.
	//
	// Today's answer, and the default, is FIELD: the voxel's type id is a
	// field of the word and it indexes the registry. That is a shift and a
	// mask and it is what every game in this tree does.
	//
	// The other answer is RULES, for a world whose voxels have no type id at
	// all -- the fractions of several materials, say, where what a voxel
	// looks like is a threshold over them rather than a number to look up.
	// An ordered list of rules, each a conjunction of ranges over fields;
	// the first one all of whose clauses hold says which definition the
	// voxel wears, and a voxel no rule claims wears the fallback.
	//
	// The definition is still where every property lives: what the mesher
	// draws, whether the physics collides with it, whether light passes. A
	// selector only changes how the definition is found, so nothing that
	// asks a question of a voxel has to know which kind is in use. A world
	// that wants a finer distinction in one property than in another gives
	// the rules that make it and points them at definitions that differ in
	// that property alone.
	//
	// simplified: there is no memo. A rule list is walked per voxel that is
	// asked about, which is a few comparisons where FIELD is a shift and a
	// mask. The upgrade path, when a rule list is long enough to show up in
	// a mesh time, is a cache keyed by the fields the rules actually read,
	// cut to a few bits each -- but that wants a measurement to size it, and
	// there is nothing to measure yet.

	// One test in a rule: the field's value is between lo and hi, both ends
	// included. A clause on an unbound field never holds.
	struct VoxelRuleClause
	{
		VoxelField field;
		uint32_t lo = 0;
		uint32_t hi = 0xffffffffUL;

		VoxelRuleClause(){}
		VoxelRuleClause(const VoxelField &field, uint32_t lo, uint32_t hi):
			field(field), lo(lo), hi(hi){}

		bool holds(uint32_t word) const {
			if(!field.bound())
				return false;
			uint32_t v = field.get(word);
			return v >= lo && v <= hi;
		}
	};

	struct VoxelRule
	{
		// Every clause has to hold. An empty list holds, which is how a rule
		// says "anything left".
		sv_<VoxelRuleClause> clauses;
		// Which definition a voxel matching this rule wears
		VoxelTypeId result = VOXELTYPEID_UNDEFINED;

		bool holds(uint32_t word) const {
			for(const VoxelRuleClause &c : clauses){
				if(!c.holds(word))
					return false;
			}
			return true;
		}
	};

	struct VoxelSelector
	{
		enum Kind {
			FIELD = 0,
			RULES = 1,
		};
		uint8_t kind = FIELD;
		// RULES: walked in order, first match wins
		sv_<VoxelRule> rules;
		// RULES: what a voxel no rule claims wears
		VoxelTypeId fallback = VOXELTYPEID_UNDEFINED;

		// Which definition this voxel wears. format is the world's, which is
		// where the id role lives for the FIELD kind.
		VoxelTypeId id_of(uint32_t word, const VoxelFormat &format) const {
			if(kind != RULES)
				return format.id_of(word);
			for(const VoxelRule &r : rules){
				if(r.holds(word))
					return r.result;
			}
			return fallback;
		}

		// Every rule points at a definition that exists, and no rule is
		// unreachable behind an earlier one that claims everything. count is
		// how many definitions the registry has. why, when given, gets the
		// first reason it did not.
		bool validate(size_t count, ss_ *why = nullptr) const;
	};

	// Asserts what a selector does: FIELD is the format's id role, RULES
	// takes the first match, an empty clause list claims what is left, and a
	// clause on an unbound field never holds. Runs with
	// voxel_format_self_test().
	bool voxel_selector_self_test();
}
// vim: set noet ts=4 sw=4:
