import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;
using haxe.macro.ExprTools;

typedef ViewContext = {
	expr: Expr,
	blocks: Array<Block>
}

typedef Cell = {
	tag: String,
	attrs: Dynamic,
	children: Array<Dynamic>
}

enum Block {
	ElementBlock(data: Element, pos: PosInfo);
	ExprBlock(e: Expr, pos: PosInfo);
}

typedef BlockWithChildren = {
	block: Block,
	children: Array<BlockWithChildren>, 
	indent: Int,
	line: Int,
	parent: BlockWithChildren
}

typedef Selector = {
	tag: String,
	classes: Array<String>,
	id: String
}

typedef Element = {
	selector: Selector,
	attributes: Null<Expr>,
	inlineAttributes: Array<InlineAttribute>,
	content: Null<Expr>
}

typedef PosInfo = {
	file: String,
	line: Int,
	start: Int,
	end: Int
}

typedef InlineAttribute = {
	attr: String,
	value: Expr
}

typedef ObjField = {field : String, expr : Expr};

typedef Lines = Map<Int, Int>;

class ViewBuilder {
	
	static var lines: Lines;
	
	macro static public function build(): Array<Field> {
		return Context.getBuildFields().map(inlineView);
	}
	
	static function inlineView(field: Field) {
		return switch (field.kind) {
			case FieldType.FFun(func):
				lines = new Lines();
				func.expr.iter(parseBlock);
				field;
			default: field;
		}
	}
	
	static function parseBlock(e: Expr) {
		switch (e.expr) {
			case ExprDef.ECall(_, _):			
				parseCalls(e, {
					expr: e,
					blocks: []
				});
			default:
		}
		e.iter(parseBlock);
	}
	
	static function parseCalls(e: Expr, ctx: ViewContext) {
		switch (e) {
			case _.expr => ExprDef.ECall(callExpr, params):
				var block = chainElement(params, e);
				if (block != null) {
					ctx.blocks.push(block);
					parseCalls(callExpr, ctx);
				}
			case macro (view):
				ctx.expr.expr = createExpr(orderBlocks(ctx)).expr;
			default:
		}
	}
	
	static function createExpr(list: Array<BlockWithChildren>, ?prepend: Expr): ExprOf<Array<Dynamic>> {
		var exprList: Array<Expr> = [];
		if (prepend != null) exprList.push(prepend);
		for (item in list) {
			switch (item.block) {
				case Block.ElementBlock(data, _):
					var tag = Context.makeExpr(data.selector.tag, Context.currentPos());
					//var attributes = createAttrsExpr(data);
					exprList.push(macro {
						tag: ${tag},
						attrs: ${createAttrsExpr(data)},
						children: (${createExpr(item.children, data.content)}: Array<Dynamic>)
					});
				case Block.ExprBlock(e, _):
					exprList.push(e);
					//trace('Children in expr: '+item.children.length);
				default:
			}
		}
		return macro ($a{exprList}: Array<Dynamic>);
	}
	
	static function createAttrsExpr(data: Element): Expr {
		var e: Expr;
		var id = data.selector.id;
		var className = data.selector.classes.join(' ');
		
		var fields: Array<ObjField> = [];
		
		if (data.attributes != null) {
			switch (data.attributes.expr) {
				case ExprDef.EObjectDecl(f):
					fields = f;
				default:
					// concat objects
					var attrs: Array<Expr> = [];
					if (id != '')
						attrs.push(macro Reflect.setField(t, 'id', $v { id } ));
					if (className != '')
						attrs.push(macro Reflect.setField(t, 'class', $v{className}));
					for (attr in data.inlineAttributes) {
						var key = attr.attr;
						attrs.push(macro Reflect.setField(t, $v{key}, ${attr.value}));
					}
					if (attrs.length > 0)
					return macro {
						var t = ${data.attributes};
						$b{attrs};
						t;
					};
						else return macro { };
			}
		}
		
		if (id != '')
			addToObjFields(fields, 'id', macro $v{id});
		if (className != '')
			addToObjFields(fields, 'class', macro $v{className});
		for (attr in data.inlineAttributes) {
			addToObjFields(fields, attr.attr, attr.value);
		}
		return {
			expr: ExprDef.EObjectDecl(fields), pos: Context.currentPos()
		};
	}
	
	static function addToObjFields(fields: Array<ObjField>, key: String, expr: Expr) {
		var exists = false;
		fields.map(function(field: ObjField) {
			if (field.field == key) {
				exists = true;
				field.expr = expr;
			}
		});
		if (!exists) {
			fields.push({
				field: key,
				expr: expr
			});
		}
	}
	
	static function orderBlocks(ctx: ViewContext) {
		ctx.blocks.reverse();
		var list: Array<BlockWithChildren> = [];
		var current: BlockWithChildren = null;
		for (block in ctx.blocks) {
			var line = switch (block) {
				case Block.ElementBlock(_, pos) | Block.ExprBlock(_, pos):
					pos.line;
			}
			var indent = lines.get(line);
			var addTo: BlockWithChildren = current;
			
			if (addTo != null) {
				if (indent == current.indent) {
					/*if (current.line == line)
						addTo = current;
					else*/
						addTo = current.parent;
				} else if (indent < current.indent) {
					var parent = current.parent;
					while (parent != null && indent <= parent.indent) {
						parent = parent.parent;
					}
					addTo = parent;
				}
			}
			
			var positionedBlock = {
				block: block,
				children: [],
				indent: indent,
				line: line,
				parent: addTo
			};
			
			current = positionedBlock;
			
			if (addTo != null)
				addTo.children.push(positionedBlock);
			else
				list.push(positionedBlock);
		}
		return list;
	}
	
	static function element(): Element {
		return {
			selector: {
				tag: '',
				classes: [],
				id: '',
			},
			attributes: null,
			inlineAttributes: [],
			content: null
		};
	}
	
	static function chainElement(params: Array<Expr>, callExpr: Expr): Null<Block> {
		if (params.length == 0 || params.length > 3) 
			return null;
		
		if (params.length == 1) {
			var e = params[0];
			switch (e.expr) {
				case ExprDef.EParenthesis(expr):
					return Block.ExprBlock(expr, posInfo(e));
				default:
			}
		}
				
		var element = element();
		var e = params[0];
		switch (e.expr) {
			case ExprDef.EConst(c):
				switch (c) {
					case Constant.CIdent(s):
						element.selector.tag = s;
					default: return null;
				}
			case ExprDef.EField(_, _) | ExprDef.EBinop(_, _, _) | ExprDef.EArray(_, _):
				// get all attributes
				callExpr.iter(getAttr.bind(_, element.inlineAttributes));
				element.selector = parseSelector(e.toString().replace(' ', ''));
			default: return null;
		}
		
		if (params.length > 1)
			element.attributes = params[1];
		
		if (params.length > 2)
			element.content = params[2];
			
		return Block.ElementBlock(element, posInfo(e));
	}
	
	static function getAttr(e: Expr, attributes: Array<InlineAttribute>) {
		switch (e.expr) {
			case ExprDef.EArray(prev, _ => macro $a=$b):
				switch (a.expr) {
					case ExprDef.EConst(_ => Constant.CIdent(s)):
						attributes.push({
							attr: s,
							value: b
						});
					default:
				}
			default:
		}
		e.iter(getAttr.bind(_, attributes));
	}
	
	static function parseSelector(selector: String): Selector {
		var attr = ~/\[(.*?)\]/g;
		selector = attr.replace(selector, '');
		selector = selector.replace('.', ',.').replace('+', ',+');
		var parts: Array<String> = selector.split(',');
		
		var tag = '';
		var id = '';
		var classes: Array<String> = [];
		
		for (part in parts) {
			var value = part.substr(1);
			switch (part.charAt(0)) {
				case '.': classes.push(value);
				case '+': id = value;
				default: tag = part;
			}
		}
		
		return {
			tag: tag, 
			classes: classes,
			id: id
		};
	}
	
	//#pos(src/Main.hx:71: lines 71-73)
	static function posInfo(e: Expr): PosInfo {
		var pos = e.pos;
		var info = Std.string(pos);
		var check = ~/([0-9]+): characters ([0-9]+)-([0-9]+)/;
		check.match(info);
		var line = 0;
		var start = 0;
		var end = 0;
		try {
			line = Std.parseInt(check.matched(1));
			start = Std.parseInt(check.matched(2));
			end = Std.parseInt(check.matched(3));
		} catch (error: Dynamic) {
			var subs = [];
			e.iter(function(e) {
				subs.push(e);
			});
			if (subs.length > 0) {
				return posInfo(subs[subs.length-1]);
			}
		}

		if (!lines.exists(line) || lines.get(line) > start)
			lines.set(line, start);
		
		return {
			file: Context.getPosInfos(pos).file,
			line: line,
			start: start,
			end: end
		};
	}
	
}