import sys
import re
import copy

ENABLE_LOG = False
IN_PLACE = False
# Not actually needed because indent level is autodetected for eaach block
IGNORE_FIRST_BLOCK_LEVEL = False

def log(message):
	if ENABLE_LOG:
		print("-!- "+message)

input_filenames = []
for a in sys.argv[1:]:
	if a == '-v':
		ENABLE_LOG = True
	elif a == '-i':
		IN_PLACE = True
	elif a == '-b':
		IGNORE_FIRST_BLOCK_LEVEL = True
	else:
		input_filenames.append(a)

class ParenMatch:
	def __init__(self):
		self.level = {
			"{}": 0,
			"[]": 0,
			"()": 0,
			"''": 0,
			'""': 0,
			"<>": 0,
			'=;': 0,
			'/**/': 0,
			'//': 0,
			'#': 0,
		}
		self.assignment_begin_paren_level = 0

	def feed_part(self, line, i):
		if self.level["/**/"] > 0:
			if line[i:i+2] == '*/':
				self.level["/**/"] = 0
				return i + 2
			return i + 1
		if self.level["//"] > 0:
			if line[i] == '\n':
				self.level["//"] = 0
			return i + 1
		if self.level["''"] > 0:
			if line[i] == "\\":
				return i + 2
			if line[i] == "'":
				self.level["''"] = 0
			return i + 1
		if self.level['""'] > 0:
			if line[i] == "\\":
				return i + 2
			if line[i] == '"':
				self.level['""'] = 0
			return i + 1
		if line[i] == '/':
			if line[i+1] == '*':
				self.level["/**/"] = 1
				return i + 1
			if line[i+1] == '/':
				self.level["//"] = 1
				return i + 1
		if line[i] == '=':
			if line[i+1] not in '=<>!' and line[i-1] not in '=<>!':
				self.level["=;"] = 1
				self.assignment_begin_paren_level = self.level["()"]
				return i + 2
		if line[i] == ';':
			self.level["<>"] = 0
			if self.level["=;"] > 0:
				self.level["=;"] = 0
				return i + 1
		if self.level["#"] > 0:
			if line[i] == '\n' and line[i-1] != '\\':
				self.level["#"] = 0
			return i + 1
		if line[i] == '#':
			self.level["#"] = 1
			return i + 1
		if line[i] == '<':
			if line[i-1] != '<' and line[i+1] != '<':
				self.level["<>"] += 1
		if line[i] == '>':
			self.level["<>"] -= 1
		if line[i] in ["|", "&", "(", ")", "]", "["]:
			self.level["<>"] = 0
		for k in ["{}", "[]", "()", "''", '""']:
			if line[i] == k[0]:
				self.level[k] += 1
				return i + 1
			if line[i] == k[1]:
				self.level[k] -= 1
				if self.level[k] < 0:
					log("WARNING: resetting negative "+k+" level")
					self.level[k] = 0
				if k == "()" and self.assignment_begin_paren_level > self.level[k]:
					self.level["=;"] = 0
				return i + 1
		return i + 1

	def feed_line(self, line):
		i = 0
		while True:
			i = self.feed_part(line, i)
			if i == len(line):
				break

class DetectedBlock:
	def __init__(self, line_i, start_level, base_indent_level, base_levels):
		# If a block starts at the end of some line, the indentation of the
		# block should always be one tab level, not more like uncrustify makes
		# it in case the block belongs to a function parameter
		self.start_line = line_i
		self.open_level = start_level
		self.base_indent_level = base_indent_level
		self.inner_indent_level = None  # Detected level (which can be wrong)
		self.base_levels = base_levels  # Basae ParenMatch levels inside block

class State:
	def __init__(self):
		self.match = ParenMatch()
		self.blocks = [] # Stack
		self.assign_multiline_params_paren_level = None
		self.paren_level_indentations = {}  # Level -> starting indentation level

		# Output values
		self.indent_fix_amount = 0

	def print_debug_state(self, level_before, level_after):
		if self.blocks:
			log("base_levels : "+repr(self.blocks[-1].base_levels))
		log("level_before: "+repr(level_before))
		log("level_after : "+repr(level_after))

	def fix_indent(self, d, description):
		if d == 0:
			return
		self.indent_fix_amount += d
		log("indent"+("+="+str(d) if d >= 0 else "-="+str(-d))+": "+description)

	def get_top_block_base_levels(self):
		if not self.blocks:
			return ParenMatch().level
		top_block = self.blocks[-1]
		return top_block.base_levels

	def feed_line(self, line, line_i):
		self.indent_fix_amount = 0

		if line.strip() == "":
			return

		level_before = copy.copy(self.match.level)
		self.match.feed_line(line)
		level_after = copy.copy(self.match.level)

		line_is_comment = bool(re.match(r'[\t ]*//.*', line))
		if level_before['/**/'] > 0 or level_after['/**/'] > 0:
			line_is_comment = True

		line_is_macro = (level_before['#'] > 0 or level_after['#'] > 0)

		if line_is_macro:
			# Leave macros as-is
			return

		indent_level = 0
		space_count = 0
		for c in line:
			if c == "\t":
				indent_level += 4
			elif c == " ":
				indent_level += 1
			else:
				break

		if not line_is_comment and not line_is_macro:
			if level_after["()"] > level_before["()"]:
				for paren_level in range(level_before["()"], level_after["()"]):
					self.paren_level_indentations[paren_level] = indent_level
					log("Detected paren level "+str(paren_level)+" indentation "+
							str(indent_level))

		# Fill in inner block level of topmost block
		if (line.strip() != "" and self.blocks and
				level_after["{}"] >= level_before["{}"]):
			block = self.blocks[-1]
			if block.inner_indent_level is None:
				if re.match(r'^[ \t]*[a-z]+.*:$', line):
					block.inner_indent_level = indent_level + 4
				else:
					block.inner_indent_level = indent_level
				log("Detected inner indent level: "+str(block.inner_indent_level))

		# Final indentation level fix
		is_inside_broken_block = False

		# Fix block indentation level
		for i, block in enumerate(self.blocks):
			if IGNORE_FIRST_BLOCK_LEVEL:
				if i == 0:  # Ignore first block, it's the namespace or something
					continue
			if block.inner_indent_level is None:
				continue
			#log("block.base_indent_level: "+str(block.base_indent_level))
			#log("block.inner_indent_level: "+str(block.inner_indent_level))
			if block.inner_indent_level - block.base_indent_level != 4:
				d = block.base_indent_level - block.inner_indent_level + 4
				self.fix_indent(d, "Fixing broken block indent")
				is_inside_broken_block = True

		# Hack: If line contains 'else', it has to be on lower indentation level
		# This has to be done because we do stuff on a line-by-line basis
		#if re.match(r'^.*}[\t ]else[\t ]+(if|).*$', line):
		#	self.fix_indent(-4, "Hack: else")

		# Another hack; "case FOO: {" must be on lower indetation level
		if not line_is_comment and not line_is_macro:
			if re.match(r'^.*:[\t ]*{.*$', line):
				self.fix_indent(-4, "Hack: case Foo: {")

		# Another hack; "public:, private:, protected:"
		if not line_is_comment and not line_is_macro:
			if self.blocks:
				top_block = self.blocks[-1]
				if (re.match(r'^[\t ]*(public|private|protected):$', line) and
						top_block.base_indent_level != indent_level):
					d = top_block.base_indent_level - indent_level
					self.fix_indent(d, "Hack: public/private/protected at"+
							" wrong level")

		if not line_is_comment and not line_is_macro:
			# Block level detection: Detect block starts
			# Really works only if there is only one { on the line
			m = re.match(r'.*{', line)
			m2 = re.match(r'.*}.*{', line)
			if m and not m2 and level_after["{}"] > level_before["{}"]:
				block_open_level = level_before["{}"]
				block_indent_level = indent_level
				# Use the indent level of the outside block if possible
				if self.blocks:
					parent = self.blocks[-1]
					if parent.inner_indent_level is not None:
						block_indent_level = parent.inner_indent_level
				# If this line closes parenthesis, take the indent level from the
				# parentheesis starting indentation level
				use_paren_based_indentation = False
				if level_after["()"] < level_before["()"]:
					base_paren_level = level_after["()"]
					block_indent_level = self.paren_level_indentations[base_paren_level]
					use_paren_based_indentation = True
				log("Detected block level "+str(block_open_level)+" begin; indent "+
						str(block_indent_level))
				self.blocks.append(DetectedBlock(line_i, block_open_level,
						block_indent_level, level_after))
				if not use_paren_based_indentation:
					# Fix { to be on the correct indentation level
					d = block_indent_level - indent_level
					self.fix_indent(d, "Fixing { to have correct indentation")

		if not line_is_comment and not line_is_macro:
			# Update current block level
			while self.blocks:
				block = self.blocks[-1]
				if level_after["{}"] <= block.open_level:
					base_indent_level = block.base_indent_level
					log("Detected block level "+str(block.open_level)+
							" end (begun on line "+str(block.start_line)+
							", base_indent_level="+str(base_indent_level)+")")
					self.blocks = self.blocks[:-1]
					# Fix indentation of last line if it doesn't contain
					# anything special at all (only '}' or ';', no ')')
					# This applies to blocks that are not parameters or are not
					# being assigned to anything
					self.print_debug_state(level_before, level_after)
					if re.match(r'^[ \t]*[};]+$', line) and level_after["{}"] == 0:
						self.fix_indent(-4, "Fixing indent of simple block end")
				else:
					break

		# Can't do this because we don't have the correct logic for all
		# constructs; we only track block level
		## Fix indentation level
		#wanted_indent_level = 0
		#for i, block in enumerate(self.blocks):
		#	if IGNORE_FIRST_BLOCK_LEVEL:
		#		if i == 0:  # Ignore first block, it's the namespace or something
		#			continue
		#	if block.inner_indent_level is None:
		#		continue
		#	wanted_indent_level += 4
		#self.indent_fix_amount = wanted_indent_level - indent_level
		#log("Line should have indent level "+str(wanted_indent_level)+
		#		", fix amount: "+str(self.indent_fix_amount))

		if not line_is_comment and not line_is_macro:
			# Assignment-with-multiline-parameters handling
			m = re.match(r'.*=.*\(', line)
			if m and self.assign_multiline_params_paren_level is None:
				if level_after["()"] > level_before["()"]:
					log("Detected assignment with starting multi-line parameters at "+
							"paren level "+str(level_after["()"]))
					self.assign_multiline_params_paren_level = level_after["()"]

		if not line_is_comment and not line_is_macro:
			# Match sole ); without extra stuff except more parentheses
			if (self.assign_multiline_params_paren_level is not None and
					level_after["()"] < self.assign_multiline_params_paren_level):
				self.assign_multiline_params_paren_level = None
				log("Detected end of multi-line parameters")
				# Fix indentation of last line if it doesn't contain any
				# parameters
				if re.match(r'^[ \t]*[});]+$', line):
					# Indent it properly according to the current block level
					# Use the indent level of the outside block
					block_indent_level = 0
					if self.blocks:
						parent = self.blocks[-1]
						if parent.inner_indent_level is not None:
							block_indent_level = parent.inner_indent_level
					#log("block_indent_level: "+str(block_indent_level))
					#log("indent_level: "+str(indent_level))
					d = block_indent_level - indent_level
					self.fix_indent(d, "Aligning parameter-less end of multi-line "+
							"parameters")

		if not line_is_comment and not line_is_macro:
			added_multiline_paren_indentation = False  # Avoid adding twice
			# If inside broken indentation, do manual indentation of things
			# content because uncrustify can't bother
			if is_inside_broken_block:
				base_levels = self.get_top_block_base_levels()
				# Manual indentation of multiline () content
				if level_before["()"] > base_levels["()"]:
					self.print_debug_state(level_before, level_after)
					if base_levels["()"] < level_before["()"]:
						if base_levels["{}"] >= level_before["{}"]:
							self.fix_indent(8,
									"Indenting multiline () in broken block")
							added_multiline_paren_indentation = True
				# Manual indentation of multiline assignment
				self.print_debug_state(level_before, level_after)
				base_levels = self.get_top_block_base_levels()
				if (level_before["=;"] > base_levels["=;"] and
						not re.match(r'^.*[ \t]=( |\t|\n).*$', line) and
						not added_multiline_paren_indentation):
					self.fix_indent(4, "Indenting multiline assigmnent in "+
							"broken block")
			# If not inside broken indentation
			else:
				# Add one level to inside multiline () content because
				# uncrustify is unable to do so consistently. It randomly uses 1
				# and 2 tabs if an attempt is made to configure it to do this.
				# It is now configured to always add 1.
				# Also member initializers get correct indentation this way.
				base_levels = self.get_top_block_base_levels()
				if (level_before["()"] > base_levels["()"] and
						not re.match(r'^[ \t]*[)}\];].*$', line)):
					self.fix_indent(4, "Adding indentation to regular multiline ()")
					added_multiline_paren_indentation = True
				# Add two levels to inside multiline <> content because
				# uncrustify does not do that.
				base_levels = self.get_top_block_base_levels()
				if (level_before["<>"] > base_levels["<>"]):
					self.fix_indent(8, "Adding indentation to regular multiline <>")
					added_multiline_paren_indentation = True
				# Add one level to inside multiline assignment  content because
				# uncrustify is unable to do so consistently. It randomly uses 1
				# and 2 tabs if an attempt is made to configure it to do this.
				# It is now configured to always add 1.
				if not added_multiline_paren_indentation:
					base_levels = self.get_top_block_base_levels()
					if (level_before["=;"] > base_levels["=;"] and
							not re.match(r'^.*[ \t]=( |\t|\n).*$', line) and
							not re.match(r'^[ \t]*[)}\];].*$', line)):
						self.fix_indent(4, "Adding indentation to regular "+
								"multiline =;")

		# Log final indent fix amount
		if self.indent_fix_amount != 0:
			log("Indent has to be fixed by "+str(self.indent_fix_amount))

def fix_line(line, state):
	if state.indent_fix_amount < 0:
		remove_spaces_total = -state.indent_fix_amount
		remove_tabs = int(remove_spaces_total / 4)
		remove_spaces = remove_spaces_total - remove_tabs * 4
		#log("Removing "+str(remove_tabs)+" tabs and "+str(remove_spaces)+" spaces")
		for i in range(0, remove_tabs):
			if line[0] == '\t':
				line = line[1:]
			else:
				log("Can't remove enough tabs")
		for i in range(0, remove_spaces):
			did = False
			for i, c in enumerate(line):
				if c not in ' \t':
					break
				if c == ' ':
					line = line[0:i] + line[i+1:]
					did = True
					break
			if not did:
				log("Can't remove enough spaces")
	elif state.indent_fix_amount > 0:
		for i in range(0, state.indent_fix_amount / 4):
			line = "\t" + line
	return line

for input_filename in input_filenames:
	f = open(input_filename)
	lines = f.readlines()
	f.close()
	state = State()
	fixed_lines = []
	for line_i, orig_line in enumerate(lines):
		state.feed_line(orig_line, line_i)
		fixed_line = fix_line(orig_line, state)
		if ENABLE_LOG:
			sys.stdout.write("original "+str(line_i)+": "+orig_line)
			if fixed_line != orig_line:
				sys.stdout.write("   fixed "+str(line_i)+": "+fixed_line)
		else:
			if not IN_PLACE:
				sys.stdout.write(fixed_line)
		fixed_lines.append(fixed_line)
	if IN_PLACE:
		f.close()
		f = open(input_filename, "w")
		for line in fixed_lines:
			f.write(line)

# vim: set noet ts=4 sw=4:
