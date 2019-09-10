/*******************************************************************************
 * Copyright (c) 2017 TypeFox GmbH (http://www.typefox.io) and others.
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v1.0
 * which accompanies this distribution, and is available at
 * http://www.eclipse.org/legal/epl-v10.html
 *******************************************************************************/
package io.typefox.jflex

import com.google.common.io.CharStreams
import com.google.inject.Inject
import com.google.inject.Injector
import java.io.CharArrayReader
import java.io.InputStreamReader
import java.io.Reader
import java.lang.reflect.Field
import java.util.ArrayList
import java.util.regex.Pattern
import org.antlr.runtime.ANTLRStringStream
import org.antlr.runtime.CharStream
import org.antlr.runtime.RecognitionException
import org.antlr.runtime.Token
import org.eclipse.xtend.lib.annotations.Accessors
import org.eclipse.xtend2.lib.StringConcatenationClient
import org.eclipse.xtext.xtext.generator.AbstractXtextGeneratorFragment
import org.eclipse.xtext.xtext.generator.CodeConfig
import org.eclipse.xtext.xtext.generator.Issues
import org.eclipse.xtext.xtext.generator.model.FileAccessFactory
import org.eclipse.xtext.xtext.generator.model.GuiceModuleAccess
import org.eclipse.xtext.xtext.generator.model.TypeReference
import org.eclipse.xtext.xtext.generator.parser.antlr.ContentAssistGrammarNaming
import org.eclipse.xtext.xtext.generator.parser.antlr.GrammarNaming
import org.eclipse.xtext.xtext.generator.parser.antlr.KeywordHelper

import static extension org.eclipse.xtext.GrammarUtil.*
import static extension org.eclipse.xtext.xtext.generator.model.TypeReference.*
import static extension org.eclipse.emf.common.util.URI.*
import jflex.Main

class JFlexFragment extends AbstractXtextGeneratorFragment {
	
	@Inject FileAccessFactory fileAccessFactory
	@Inject CodeConfig codeConfig
	@Inject GrammarNaming grammarNaming
	@Inject ContentAssistGrammarNaming contentAssistNaming
	
	String userCode = null
	String declarations = null
	String rules = null
	
	@Accessors String fullFlexFile = null
	@Accessors String flexFragmentFile = null
	@Accessors String extraOptions = null
	
	@Accessors boolean generateUserCode = true
	@Accessors boolean generateIntegrationCode = true
	@Accessors boolean generateOptions = true
	@Accessors boolean generateKeywordRules = true
	@Accessors boolean generateTerminalRules = true
	
	ArrayList<String> skippedKeywords = new ArrayList<String>
	
	override checkConfiguration(Issues issues) {
		if (fullFlexFile !== null) {
			return;
		}
		val grammarURI = language.grammar.eResource.URI
		val flex = flexFragmentFile?.createURI ?: grammarURI.trimFileExtension.appendFileExtension("flex")
		val reader = new InputStreamReader(language.grammar.eResource.resourceSet.URIConverter.createInputStream(flex))
		
		// JFlex file is divided into parts by a single line starting with %%
		val pattern = Pattern::compile("^%%", Pattern::MULTILINE)
		val flexConfig = pattern.split(CharStreams.toString(reader))
		if (flexConfig.size < 2 || flexConfig.size > 3) {
			throw new RuntimeException("Invalid JFlex file: " + flex)
		}
		
		val iterator = flexConfig.iterator
		if (flexConfig.size == 3) {
			// Jflex file contains user code at the top
			userCode = iterator.next
		}
		
		// Extract declarations/options and rules
		declarations = iterator.next
		rules = iterator.next
	}
	
	override generate() {
		var fullPath = fullFlexFile
		if (fullPath === null) {
			val flexFile = flexerClassName.name.replace('.','/')+".flex"
			val file = fileAccessFactory.createTextFile(flexFile, generateFlex)
			file.writeTo(projectConfig.runtime.srcGen)
			fullPath = projectConfig.runtime.srcGen.path + "/" +flexFile
		}
		Main.main(#[
			"-d",
			fullPath.substring(0, fullPath.lastIndexOf('/')),
			fullPath])
		// custom lexer
		val customParser = fileAccessFactory.createJavaFile(customLexerName, generateCustomLexer(customLexerName, grammarNaming.getLexerClass(language.grammar)))
		customParser.writeTo(projectConfig.runtime.srcGen)
		
		val rtBindings = new GuiceModuleAccess.BindingFactory()
			.addTypeToType(grammarNaming.getLexerClass(language.grammar), getCustomLexerName)
		rtBindings.contributeTo(language.runtimeGenModule)
		
		// custom Ide lexer
		val customIDELexer = fileAccessFactory.createJavaFile(customIdeLexerName, generateCustomLexer(customIdeLexerName, contentAssistNaming.getLexerClass(language.grammar)))
		customIDELexer.writeTo(projectConfig.genericIde.srcGen)
		val ideBindings = new GuiceModuleAccess.BindingFactory()
			.addConfiguredBinding('ideLexer', '''
			binder.bind(«contentAssistNaming.getLexerClass(language.grammar)».class).to(«customIdeLexerName».class);
		''').addConfiguredBinding('ContentAssistLexerProvider', '''
			// disabled contribution from XtextAntlrGeneratorFragment2
		''')
		ideBindings.contributeTo(language.ideGenModule)
	}
	
	def getCustomRegionProvider() {
		(grammarNaming.getParserClass(language.grammar).packageName+".JFlexBasedRegionProvider").typeRef
	}
	
	override initialize(Injector injector) {
		injector.injectMembers(this)
	}
	
	private def getCustomLexerName() {
		val name = grammarNaming.getLexerClass(language.grammar)
		return new TypeReference(name.packageName + ".jflex.JFlexBased"+name.simpleName)
	}
	
	private def getCustomIdeLexerName() {
		val name = contentAssistNaming.getLexerClass(language.grammar)
		return new TypeReference(name.packageName + ".jflex.JFlexBased"+name.simpleName)
	}
	
	private def getFlexerClassName() {
		val packageName = grammarNaming.getLexerClass(language.grammar).packageName
		return new TypeReference(packageName + ".jflex."+language.grammar.simpleName+"Flexer")
	}
	
	def StringConcatenationClient generateCustomLexer(TypeReference decl, TypeReference superType) '''
		public class «decl.simpleName» extends «superType» {
			«flexerClassName» delegate = new «flexerClassName»((«Reader.typeRef»)null);
			
			@Override
			public void mTokens() throws «RecognitionException.typeRef» {
				throw new UnsupportedOperationException();
			}
			
			@Override
			public «CharStream.typeRef» getCharStream() {
				return new «ANTLRStringStream.typeRef»(data, data.length);
			}
			
			@Override
			public «Token.typeRef» nextToken() {
				return delegate.nextToken();
			}
			
			char[] data = null;
			int data_length = -1;
			
			@Override
			public void setCharStream(CharStream input) {
				try {
					«Field.typeRef» field = «ANTLRStringStream.typeRef».class.getDeclaredField("data");
					«Field.typeRef» field_n = «ANTLRStringStream.typeRef».class.getDeclaredField("n");
					field.setAccessible(true);
					field_n.setAccessible(true);
					data = (char[]) field.get(input);
					data_length = (Integer) field_n.get(input);
					reset();
				} catch (Exception e) {
					throw new RuntimeException(e);
				}
			}
			
			@Override
			public void reset() {
				delegate.reset(new «CharArrayReader.typeRef»(data, 0, data_length));
			}

			public String getErrorMessage(Token t) {
				if (t.getType() == Token.INVALID_TOKEN_TYPE)
					return String.format("No viable alternative at token '%s'", t.getText());
				
				return String.format("Unknown lexer error at '%s'", t.getText());
			}
			
			public «flexerClassName» getDelegate() {
				return delegate;
			}
		}
	'''
	
	def StringConcatenationClient generateFlex() '''
		«IF generateUserCode»
			«codeConfig.fileHeader»
			package «flexerClassName.packageName»;
			
			import java.io.Reader;
			import java.io.IOException;
			
			import org.antlr.runtime.Token;
			import org.antlr.runtime.CommonToken;
			import org.antlr.runtime.TokenSource;
			
			import static «grammarNaming.getInternalParserClass(language.grammar)».*;
			
			@SuppressWarnings({"all"})
		«ELSE»
			«IF userCode !== null»
				«userCode»
			«ENDIF»
		«ENDIF»
		%%
		
		«IF generateIntegrationCode»
			%{
				public final static TokenSource createTokenSource(Reader reader) {
					return new «flexerClassName.simpleName»(reader);
				}
			
				private int offset = 0;
				
				public void reset(Reader reader) {
					yyreset(reader);
					offset = 0;
				}
			
				@Override
				public Token nextToken() {
					try {
						int type = advance();
						if (type == Token.EOF) {
							return Token.EOF_TOKEN;
						}
						int length = yylength();
						final String tokenText = yytext();
						CommonToken result = new CommonTokenWithText(tokenText, type, Token.DEFAULT_CHANNEL, offset);
						offset += length;
						return result;
					} catch (IOException e) {
						throw new RuntimeException(e);
					}
				}
			
				@Override
				public String getSourceName() {
					return "FlexTokenSource";
				}
			
				public static class CommonTokenWithText extends CommonToken {
			
					private static final long serialVersionUID = 1L;
			
					public CommonTokenWithText(String tokenText, int type, int defaultChannel, int offset) {
						super(null, type, defaultChannel, offset, offset + tokenText.length() - 1);
						this.text = tokenText;
					}
				}
			
			%}
		«ENDIF»
		
		«IF generateOptions»
			%unicode
			%implements org.antlr.runtime.TokenSource
			%class «flexerClassName.simpleName»
			%function advance
			%public
			%int
			%eofval{
			return Token.EOF;
			%eofval}
		«ENDIF»
		
		«IF extraOptions !== null»
			«extraOptions»
		«ENDIF»
		
		«IF declarations !== null»
			«declarations»
		«ENDIF»
		
		%%
		
		«FOR kw : KeywordHelper.getHelper(language.grammar).allKeywords»
			«val rule = KeywordHelper.getHelper(language.grammar).getRuleName(kw)»
			«IF !skippedKeywords.contains(kw) && generateKeywordRules»
				<YYINITIAL> "«kw»" { return «rule»; }
			«ELSE»
				// Skipped generated keyword: "«kw»" «rule»
			«ENDIF»
		«ENDFOR»
		
		«IF rules !== null»
			«rules»
		«ENDIF»
		
		«FOR tr : language.grammar.allTerminalRules»
			«IF generateTerminalRules»
				<YYINITIAL> {«tr.name»} { return RULE_«tr.name»; }
			«ELSE»
				// Skipped generated rule: RULE_«tr.name»
			«ENDIF»
		«ENDFOR»
	'''
	
	def addSkippedKeyword(String keyword) {
		skippedKeywords.add(keyword)
	}
}