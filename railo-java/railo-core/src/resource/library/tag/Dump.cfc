component {
	
	variables.NEWLINE = Server.separator.line;
	variables.TAB     = chr(9);

	variables.default = {

		 browser : "modern"
		,console : "text"
		,debug   : "modern"
	};
	variables.supportedFormats=["simple", "text", "modern", "classic"];
	variables.bSuppressType = false;
	variables.c = [1,2,4,8,16,32,64,128,256,512,1024,2048,4096,8192,16384,32768,65536,131072,262144,524288,1048576,2097152,4194304,8388608,16777216,33554432,67108864,134217728,268435456,536870912,1073741824,2147483648];

	this.metadata.hint="Outputs the elements, variables and values of most kinds of CFML objects. Useful for debugging. You can display the contents of simple and complex variables, objects, components, user-defined functions, and other elements.";
	this.metadata.attributetype="fixed";
	this.metadata.attributes={
		var: { required:false, type:"any", hint="Variable to display. Enclose a variable name in pound signs."},
		eval: { required:false, type:"any", hint="name of the variable to display, also used as label, when no label defined."},
		expand: { required:false, type:"boolean", default:true, hint="expands views"},
		label: { required:false, type:"string", default:"", hint="header for the dump output."},
		top: { required:false, type:"number", default:9999, hint="The number of rows to display."},
		showUDFs: { required:false, type:"boolean", default:true, hint="show UDFs in cfdump output."},
		show: { required:false, type:"string", default:"all", hint="show column or keys."},
		output: { required:false, type:"string", default:"browser", hint="Where to send the results:
- browser: the result is written the the browser response stream (default).
- console: the result is written to the console (System.out).
- false: output will not be written, effectively disabling the dump."},
		metainfo: { required:false, type:"boolean", default:true, hint="Includes information about the query in the cfdump results."},
		keys: { required:false, type:"number", default:9999, hint="For a structure, number of keys to display."},
		hide: { required:false, type:"string", default:"all", hint="hide column or keys."},
		format: { required:false, type:"string", default:"", hint="specify the output format of the dump, the following formats are available by default:
- html - the default browser output
- text - this is the default when outputting to console and plain text in the browser
- classic - classic view with html/css/javascript
- simple - no formatting in the output
You can use your custom style by creating a corresponding file in the railo/dump/skins folder. Check the folder for examples.",
},
		abort: { required:false, type:"boolean", default:false, hint="stops further processing of request."},
		contextlevel: { required:false, type:"number", default:2,hidden:true},
		async: { required:false, type="boolean", default=false, hint="if true and output is not to browser, Railo builds the output in a new thread that runs in parallel to the thread that called the dump.  please note that if the calling thread modifies the data before the dump takes place, it is possible that the dump will show the modified data."},
		export: { required:false, type="boolean", default=false, hint="You can export the serialised dump with this function."}
	};


	/* ==================================================================================================
	   INIT invoked after tag is constructed                                                            =
	================================================================================================== */
	void function init(required boolean hasEndTag, component parent) {

		if (server.railo.version LT "4.2")
			throw message="you need at least version [4.2] to execute this tag";
	}

	/* ==================================================================================================
	   onStartTag                                                                                       =
	================================================================================================== */
	boolean function onStartTag(required struct attributes, required struct caller) {
		
		var attrib = arguments.attributes;

		if (attrib.output == false)			// if output is false, do nothing and exit
			return true;

		attrib.format = trim(attrib.format);
		if (attrib.format == "html")
			attrib.format = "modern";
		
		if (isEmpty(attrib.format)) {

			if (attrib.output == "console" || attrib.output == "debug") 
				attrib.format = variables.default[attrib.output];
			else
				attrib.format = variables.default.browser;
		} else if (!arrayFindNoCase(variables.supportedFormats, attrib.format)) {

			if (!fileExists('railo/dump/skins/#attrib.format#.cfm')) {
				directory name="local.allowedFormats" action="list" listinfo="name" directory="railo/dump/skins" filter="*.cfm";
				local.sFormats = valueList(allowedFormats.name);
				sFormats = replaceNoCase(sFormats, ".cfm", "", "ALL");
				throw message="format [#attrib.format#] is invalid. Only the following formats are supported: #sFormats#. You can add your own format by adding a skin file into the directory #expandPath('railo/dump/skin')#.";
			}
		}
		if (attrib.output == "debug") {
			attrib.expand = false;
		}

		//eval
		if (!structKeyExists(attrib,'var') && structKeyExists(attrib,'eval')) {

			if (!len(attrib.label))
				attrib.label = attrib.eval;

			attrib.var = evaluate(attrib.eval, arguments.caller);
		}

		// context
		var context = GetCurrentContext();
		var contextLevel = structKeyExists(attrib,'contextLevel') ? attrib.contextLevel : 2;
		contextLevel = min(contextLevel,arrayLen(context));
		if (contextLevel > 0) {
			
			variables.context = context[contextLevel].template & ":" &
					context[contextLevel].line;
		} else {
			
			variables.context = '[unknown file]:[unknown line]';
		}

		if (attrib.export) {
			try {
				attrib.var = serialize(attrib.var);
			} catch (e) {
				attrib.var = e.message;
			}
		}

		// create dump struct out of the object
		try {
			var meta = dumpStruct(structKeyExists(attrib,'var') ? attrib.var : nullValue(), attrib.top, attrib.show, attrib.hide, attrib.keys, attrib.metaInfo, attrib.showUDFs, attrib.label);
		}
		catch(e) {
			var meta = dumpStruct(structKeyExists(attrib,'var') ? attrib.var : nullValue(), attrib.top, attrib.show, attrib.hide, attrib.keys, attrib.metaInfo, attrib.showUDFs);
		}
		// set global variables
		variables.format     = attrib.format;
		variables.expand     = attrib.expand;
		variables.topElement = attrib.eval ?: "var";
		variables.colors     = getSafeColors(meta.colors);
		variables.dumpID     = createId();
		variables.hasReference = structKeyExists(meta,'hasReference') && meta.hasReference;

		if (attrib.async && (attrib.output != "browser")) {
			thread name="dump-#createUUID()#" attrib="#attrib#" meta="#meta#" context="#context#" {
				doOutput(attrib, meta);
			}
		} else {
			doOutput(attrib, meta);
		}

		if (attrib.abort)
			abort;

		return true;
	}


	function doOutput(attrib, meta) {

		variables.aOutput = [];
		variables.level = 0;

		if (attrib.format != "simple" && attrib.format != "text") {
			
			setCSS(attrib.format);
			setJS();
		}

		// sleep(5000);	// simulate long process to test async=true

		if (arguments.attrib.output == "browser" || arguments.attrib.output == true) {

			if (arguments.attrib.format == "text") {
				echo('<pre>');
				text(arguments.meta, 'title="#variables.context#"');
				writeOutput(arrayToList(variables.aOutput, ""));
				echo('</pre>' & variables.NEWLINE);
			} else {
				
				echo(variables.NEWLINE & '<!-- == dump-begin #variables.dumpID# == format: #arguments.attrib.format# !-->' & variables.NEWLINE);
				
				if (arguments.attrib.format == "simple") {

					simple(arguments.meta, 'title="#variables.context#"');
					echo(arrayToList(variables.aOutput, variables.NEWLINE));
				} else {

					echo('<div id="-railo-dump-#variables.dumpID#" class="-railo-dump modern">');
					html(arguments.meta, 'title="#variables.context#"');
					echo(arrayToList(variables.aOutput, variables.NEWLINE));
					echo('</div>' & variables.NEWLINE);
				}
				echo('<!-- == dump-end #variables.dumpID# == !-->' & variables.NEWLINE);
			}
		} else {

			if (arguments.attrib.format == "text") {
				text(arguments.meta, 'title="#variables.context#"');
			} else if (arguments.attrib.format == "simple") {
				simple(arguments.meta, 'title="#variables.context#"');
			} else {
				html(arguments.meta, 'title="#variables.context#"');
			}

			if (arguments.attrib.output == "console") {
				// echo("***<pre>#aOutput.toString()#</pre>***")
				systemOutput("/** dump #variables.dumpID# begin - #dateTimeFormat(now(), 'iso8601')# #variables.context# **/", true);
				systemOutput(arrayToList(aOutput, ""), true);
				systemOutput("/** dump #variables.dumpID# end **/", true);
			} else if (attrib.output == "debug") {
				admin action="addDump" dump="#arrayToList(aOutput, variables.NEWLINE)#";
			} else {
				file action="write" addnewline="yes" file="#arguments.attrib.output#" output="#arrayToList(aOutput, variables.NEWLINE)#";
			}
		}
	}


	string function html(required struct meta, string title="") {

		local.columnCount = structKeyExists(arguments.meta,'data') ? listLen(arguments.meta.data.columnlist) : 0;
	
		var simpleType = meta.simpleType ?: lcase(meta.type);

		if (["boolean", "date", "numeric", "string"].contains(simpleType))
			simpleType = "simple";
		else if (simpleType CT '.')
			simpleType = listLast(simpleType, '.')

		//Lookup von ColorID
		local.id     = "";
		local.fontStyle = !variables.expand ? 'style="font-style:italic;"' : '';
		// local.hidden = !variables.expand ? 'style="display:none;"' : '';

		arrayAppend(variables.aOutput, '<table class="table-dump dump-#simpleType#" #arguments.title#>');
		
		if (structKeyExists(arguments.meta, 'title')){
			id = createUUID();
			local.metaID = variables.hasReference && structKeyExists(arguments.meta,'id') ? ' [#arguments.meta.id#]' : '';
			local.comment = structKeyExists(arguments.meta,'comment') ? "<br>" & replace(HTMLEditFormat(arguments.meta.comment),chr(10),' <br>','all') : '';
			arrayAppend(variables.aOutput, '<tr class="base-header" #fontStyle# onClick="dump_toggle(this, false)">');
			arrayAppend(variables.aOutput, '<td class="border bold bgd-#simpleType# pointer" colspan="#columnCount#"><span class="nowrap">#arguments.meta.title#</span>');
			arrayAppend(variables.aOutput, '<span class="meta"><span class="nowrap">#comment#</span></span></td>');
			arrayAppend(variables.aOutput, '</tr>');
		}

		if (columnCount) {

			local.stClasses = {
				1: '<td class="border label bgd-#simpleType# pointer',
				0: '<td class="border label bgl-#simpleType#'
			};

			local.qMeta = arguments.meta.data;
			local.nodeID = len(id) ? ' name="#id#"' : '';
			local.hidden = !variables.expand && len(id) ? ' style="display:none"' : '';
			loop query="qMeta" {

				arrayAppend(variables.aOutput, '<tr class="" #hidden#>');
				
				loop from="1" to="#columnCount-1#" index="local.col" {
					
					var node = qMeta["data" & col];

					if (qMeta.highlight == 1) {
						local.bColor = col == 1 ? 1 : 0;
					} else if (qMeta.highlight == 0) {
						local.bColor = 0;
					} else if (qMeta.highlight == -1) {
						local.bColor = 1;
					} else {
						local.bColor = bitand(qMeta.highlight, variables.c[col] ?: 0) ? 1 : 0;
					}

					if (isStruct(node)) {
						arrayAppend(variables.aOutput, stClasses[bColor] & '">');
						html(node);		// recursive call
						arrayAppend(variables.aOutput, '</td>');	
					}
					else {	
/*						
// If you want to suppress the type of an element, just uncomment these lines and set the variable in the corresponding skin method below
if (variables.bSuppressType) {
							if (col == 1) {
								if (sType neq "ClassicSimpleValue" OR !bColor) {
									arrayAppend(variables.aOutput, stClasses[bColor]);
									arrayAppend(variables.aOutput, '" onClick="dump_toggle(this, true)">#HTMLEditFormat(node)#</div>');
								}
							} else {
								arrayAppend(variables.aOutput, stClasses[bColor]);
								arrayAppend(variables.aOutput, '">');
								arrayAppend(variables.aOutput, HTMLEditFormat(node));
								arrayAppend(variables.aOutput, '</div>');
							}
						} else { */
							if (col == 1) {
								arrayAppend(variables.aOutput, stClasses[bColor]);
								if (arguments.meta.colorID == "1onzgocz2cmqa") { // Simple Values are not clickable
									arrayAppend(variables.aOutput, '">#HTMLEditFormat(node)#</td>');
								} else {
									if (arguments.meta.colorID == "15jnbij2ut8kx" && qMeta.currentRow == 1) { // Reset removed columns
										arrayAppend(variables.aOutput, ' query-reset" title="Restore columns" onClick="dump_resetColumns(this)">&nbsp;</td>');
									} else {
										if (bColor and columnCount == 3) { // ignore for non query elements, that have several columns
											arrayAppend(variables.aOutput, '" onClick="dump_toggle(this, true)">#HTMLEditFormat(node)#</td>');
										} else {
											arrayAppend(variables.aOutput, '">#HTMLEditFormat(node)#</td>');
										}
									}
								}
							} else {
								arrayAppend(variables.aOutput, stClasses[bColor]);
								if (arguments.meta.colorID == "15jnbij2ut8kx" && bColor) { // Allow JS remove columns
									arrayAppend(variables.aOutput, '" title="Click to remove column" onClick="dump_hideColumn(this, #col-1#)"');
								}
								arrayAppend(variables.aOutput, '">');
								arrayAppend(variables.aOutput, HTMLEditFormat(node));
								arrayAppend(variables.aOutput, '</td>');
							}
/*						} */
					}
				}
				arrayAppend(variables.aOutput, stClasses[bColor] & '" style="display:none"></td></tr>');
			}
		}
		arrayAppend(variables.aOutput, '</table>');
	}


	/* ==================================================================================================
		simple                                                                                          =
	================================================================================================== */
	string function simple(required struct meta, string title = "") {

		local.columnCount = structKeyExists(arguments.meta,'data') ? listLen(arguments.meta.data.columnlist) : 0;
		local.id    = "";
		local.stColors = variables.colors[arguments.meta.colorID];
		arrayAppend(variables.aOutput, '<table cellpadding="1" cellspacing="0" border="1" #arguments.title#>');
		if (structKeyExists(arguments.meta, 'title')){
			id = createUUID();
			local.metaID = variables.hasReference && structKeyExists(arguments.meta,'id') ? ' [#arguments.meta.id#]' : '';
			local.comment = structKeyExists(arguments.meta,'comment') ? "<br>" & replace(HTMLEditFormat(arguments.meta.comment),chr(10),' <br>','all') : '';
			arrayAppend(variables.aOutput, '<tr>');
			arrayAppend(variables.aOutput, '<td colspan="#columnCount#" bgColor="#stColors.highLightColor#"><span class="nowrap">#arguments.meta.title#</span>');
			arrayAppend(variables.aOutput, '<span><span class="nowrap">#comment#</span></span></td>');
			arrayAppend(variables.aOutput, '</tr>');
		}
		if (columnCount) {

			local.qMeta = arguments.meta.data;
			local.nodeID = len(id) ? ' name="#id#"' : '';
			loop query="qMeta" {
				arrayAppend(variables.aOutput, '<tr>');
				local.col = 1;
				loop from="1" to="#columnCount-1#" index="col" {
					var node = qMeta["data" & col];

					if (qMeta.highlight == 1) {
						local.sColor = col == 1 ? stColors.highLightColor : stColors.normalColor;
					} else if (qMeta.highlight == 0) {
						local.sColor = stColors.normalColor;
					} else if (qMeta.highlight == -1) {
						local.sColor = stColors.highLightColor;
					} else {
						local.sColor = bitand(qMeta.highlight, variables.c[col] ?: 0) ? stColors.highLightColor : stColors.normalColor;
					}

					if (isStruct(node)) {
						arrayAppend(variables.aOutput, '<td bgcolor="#sColor#">');
						simple(node);
						arrayAppend(variables.aOutput, '</td>');	
					}
					else {	
						arrayAppend(variables.aOutput, '<td bgcolor="#sColor#">#HTMLEditFormat(node)#</td>');
					}
				}
				arrayAppend(variables.aOutput, '</tr>');
			}
		}
		arrayAppend(variables.aOutput, '</table>');
	}


	/* ==================================================================================================
	   text                                                                                             =
	================================================================================================== */
	string function text(required struct meta, string title = "") {

		var dataCount = structKeyExists(arguments.meta,'data') ? listLen(arguments.meta.data.columnlist) - 1 : 0;
		var indent = repeatString("    ", variables.level);
		var type = structKeyExists(arguments.meta,'type') ? arguments.meta.type : '';
		variables.level++;
		// title
		if (structKeyExists(arguments.meta, 'title')) {
			arrayAppend(variables.aOutput, trim(arguments.meta.title));
			arrayAppend(variables.aOutput, structKeyExists(arguments.meta,'comment') ? ' [' & trim(arguments.meta.comment) & ']' : '');
			arrayAppend(variables.aOutput, variables.NEWLINE);
		}

		// data
		if (dataCount > 0) {

			var qRecords = arguments.meta.data;

			loop query=qRecords {
				var needNewLine = true;

				for(var x=1; x <= dataCount; x++) {
					var node = qRecords["data" & x];
					if (needNewLine) {
						arrayAppend(variables.aOutput, variables.NEWLINE & indent);
						needNewLine = false;
					}

					if (type == "udf") {
						if (needNewLine) {
							arrayAppend(variables.aOutput, len(trim(node)) == 0 ? "[blank] " : node & " ");
						} else {
							arrayAppend(variables.aOutput, len(trim(node)) == 0 ? "[blank] " : node & " ");
						}
					} else if (isStruct(node)) {
						this.text(node, "");
					} else if (len(trim(node)) GT 0) {
						arrayAppend(variables.aOutput, node & " ");
					}

				}
			}
		}

		variables.level--;
	}


	string function createId() {

		return  "x" & createUniqueId();
	}


	string function setCSS(format="modern") {

		var colors = getColorScheme(arguments.format);

		// echo(CallStackGet('text'));

		savecontent variable="local.style" trim=true { echo('

			<style>
				.-railo-dump.modern .nowrap { white-space: nowrap; }
				.-railo-dump.modern .bold   { font-weight: bold; }
				.-railo-dump.modern .nobold { font-weight: normal; }
				.-railo-dump.modern .meta   { font-weight: normal; }
				.-railo-dump.modern .table-dump {font-family: Verdana,Geneva,Arial,Helvetica,sans-serif; font-size: 11px; background-color: ##eee;color: ##000; border-spacing: 1px; border-collapse:separate; }
				.-railo-dump.modern .pointer 	{ cursor: pointer; }
				.-railo-dump.modern .border 	{ border: 1px solid ##000; padding: 2px; }
				.-railo-dump.modern .border.label { margin: 1px 1px 0px 1px; vertical-align: top; text-align: left; }
				.-railo-dump.modern .border.label .bgd-simple, .-railo-dump.modern .border.label .bgl-simple	{ cursor: initial; }
				.-railo-dump.modern .query-reset { background: url(data:image/gif;base64,R0lGODlhCQAJAIABAAAAAP///yH5BAEAAAEALAAAAAAJAAkAAAIRhI+hG7bwoJINIktzjizeUwAAOw==) no-repeat; height:18px; background-position:2px 4px; background-color: ##C9C; }
			');

			loop collection=colors item="local.value" index="local.key" {

				echo(".-railo-dump.modern .bgd-#lcase(key)# { background-color: ###value.dark#; } ");
				echo(".-railo-dump.modern .bgl-#lcase(key)# { background-color: ###value.light#; } ");
			}

			echo("</style>");
		} // savecontent

		arrayAppend(variables.aOutput, style);
	}

	string function setJS() {
		arrayAppend(variables.aOutput, '<script type="text/javascript">');
		arrayAppend(variables.aOutput, 'var sBase = "' & variables.topElement & '";');

/* 		arrayAppend(variables.aOutput, "
//	Uncomment, if you want to work on the real Javascript code

function dump_toggle(oObj, bReplaceInfo){
	var node = oObj;
	node = node.nextElementSibling || node.nextSibling;
	while(node && (node.nodeType === 1) && (node !== oObj)) {
		var oOldNode = node;
		s = oOldNode.style;
		if(s.display=='none') {
			s.display='';
		} else {
			s.display='none';
		}
		node = node.nextElementSibling || node.nextSibling;
	}
	if (oObj.style.fontStyle=='italic') {
		oObj.style.fontStyle='normal';
	} else {
		oObj.style.fontStyle='italic';
	}
	if (bReplaceInfo) {
		var oParentNode = oObj;
		var sText = '';
		var sInnerText = '';
		while (oParentNode) {
			sText = oParentNode.innerHTML;
			if (isNumber(sText)) { 
				sText = '[' + sText + ']'; 
			} 
			if (sInnerText == '') {
				sInnerText = sText;
			} else {
				sInnerText = sText + (sInnerText.substring(0,1) == '[' ? '' : '.') + sInnerText;
			}
			oParentNode = getNextLevelUp(oParentNode);
		}
		oOldNode.innerHTML = sBase + (sInnerText.substring(0,1) == '[' ? '' : '.') + sInnerText;
		selectText(oOldNode);
	}
}

function isNumber(n) {
	return !isNaN(parseFloat(n)) && isFinite(n);
}

function getNextLevelUp(oNode) {
	oCurrent = oNode;
	while (oNode) {
		oNode = oNode.parentNode;
		if (oNode && oNode.className && oNode.className.toUpperCase() == 'TRTABLEDUMP') {
			if (!oNode.firstElementChild) {
				var oTmp = oNode.children[0];
			} else {
				var oTmp = oNode.firstElementChild;
			}
			if (oTmp) {
				if (oTmp !== oCurrent && oTmp.className.toUpperCase().indexOf('NAME TDCLICK') != -1) {
					return oTmp;
				}
			}
			oNode = oNode.parentNode;
		}
	}
	return;
}

function selectText(oElement) {
	if (document.body.createTextRange) { // ms
		var range = document.body.createTextRange();
		range.moveToElementText(oElement);
		range.select();
	} else if (window.getSelection) { // moz, opera, webkit
		var selection = window.getSelection();			
		var range = document.createRange();
		range.selectNodeContents(oElement);
		selection.removeAllRanges();
		selection.addRange(range);
	}
}

function dump_hideColumn(oObj, iCol) {
	var oNode = oObj.parentNode;
	while(oNode && (oNode.nodeType === 1)) {
		var oChildren = oNode.children;
		if (oChildren[iCol] && oChildren[iCol].tagName == 'TD') {
			oChildren[iCol].style.display = 'none';
		}
		oNode = oNode.nextElementSibling || oNode.nextSibling;
	}

}

function dump_resetColumns(oObj, iCol) {
	var oNode = oObj.parentNode;
	while(oNode && (oNode.nodeType === 1)) {
		var oChildren = oNode.children;
		for (var i=0;i<oChildren.length-1;i++) {
			if (i == oChildren.length-1) {
				oChildren[i].style.display = 'none';
			} else {
				oChildren[i].style.display = '';
			}
		}
		oNode = oNode.nextElementSibling || oNode.nextSibling;
	}
}
"); */

		// compressed JS Version
		arrayAppend(variables.aOutput, 'function dump_toggle(e,t){var n=e;n=n.nextElementSibling||n.nextSibling;while(n&&n.nodeType===1&&n!==e){var r=n;s=r.style;if(s.display=="none"){s.display=""}else{s.display="none"}n=n.nextElementSibling||n.nextSibling}if(e.style.fontStyle=="italic"){e.style.fontStyle="normal"}else{e.style.fontStyle="italic"}if(t){var i=e;var o="";var u="";while(i){o=i.innerHTML;if(isNumber(o)){o="["+o+"]"}if(u==""){u=o}else{u=o+(u.substring(0,1)=="["?"":".")+u}i=getNextLevelUp(i)}r.innerHTML=sBase+(u.substring(0,1)=="["?"":".")+u;selectText(r)}}function isNumber(e){return!isNaN(parseFloat(e))&&isFinite(e)}function getNextLevelUp(e){oCurrent=e;while(e){e=e.parentNode;if(e&&e.className&&e.className.toUpperCase()=="TRTABLEDUMP"){if(!e.firstElementChild){var t=e.children[0]}else{var t=e.firstElementChild}if(t){if(t!==oCurrent&&t.className.toUpperCase().indexOf("NAME TDCLICK")!=-1){return t}}e=e.parentNode}}return}function selectText(e){if(document.body.createTextRange){var t=document.body.createTextRange();t.moveToElementText(e);t.select()}else if(window.getSelection){var n=window.getSelection();var t=document.createRange();t.selectNodeContents(e);n.removeAllRanges();n.addRange(t)}}function dump_hideColumn(e,t){var n=e.parentNode;while(n&&n.nodeType===1){var r=n.children;if(r[t]&&r[t].tagName=="TD"){r[t].style.display="none"}n=n.nextElementSibling||n.nextSibling}}function dump_resetColumns(e,t){var n=e.parentNode;while(n&&n.nodeType===1){var r=n.children;for(var i=0;i<r.length-1;i++){if(i==r.length-1){r[i].style.display="none"}else{r[i].style.display=""}}n=n.nextElementSibling||n.nextSibling}}');

		arrayAppend(variables.aOutput, '</script>');
	}


	function getColorScheme(skinName="modern") {

		var result = {

			 Array:          { dark: '9c3', light: 'cf3' }
			,Component:      { dark: '9c9', light: 'cfc' }
			,Mongo:          { dark: '393', light: '966' }
			,Object:         { dark: 'c99', light: 'fcc' }
			,JavaObject:     { dark: 'c99', light: 'fcc' }
			,Query:          { dark: 'c9c', light: 'fcf' }
			,Simple:         { dark: 'f60', light: 'fc9' }
			,Struct:         { dark: '99f', light: 'ccf' }
			,SubXML:         { dark: '996', light: 'cc9' }
			,XML:            { dark: 'c99', light: 'fff' }
			,white:          { dark: 'fff', light: 'ccc' }
			,Method:         { dark: 'c6f', light: 'fcf' }
			,PublicMethods:  { dark: 'fc9', light: 'ffc' }
			,PrivateMethods: { dark: 'fc3', light: 'f96' }
		};

		if (skinName != "modern" && fileExists("railo/dump/skins/#arguments.skinName#.cfm")) {

			var skin = fileRead("railo/dump/skins/#arguments.skinName#.cfm");

			try {

				result = deserializeJSON(skin);
			}
			catch(ex) {}
		}

		return result;
	}


	private struct function getSafeColors(required struct stColors) {
		local.stRet = {};
		loop collection="#arguments.stColors#" index="local.sKey" item="local.stColor" {
			loop collection="#stColor#" index="local.sColorName" item="local.sColor" {
				if (len(sColor) == 4) {
					sColor = "##" & sColor[2] & sColor[2] & sColor[3] & sColor[3] & sColor[4] & sColor[4];
				}
				stRet[sKey][sColorName] = sColor;
			}
		}
		return stRet;
	}

}