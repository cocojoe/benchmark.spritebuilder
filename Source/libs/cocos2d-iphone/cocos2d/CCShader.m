//
// Copyright 2011 Jeff Lamarche
//
// Copyright 2012 Goffredo Marocchi
//
// Copyright 2012 Ricardo Quesada
//
//
// Redistribution and use in source and binary forms, with or without modification, are permitted provided
// that the following conditions are met:
//	1. Redistributions of source code must retain the above copyright notice, this list of conditions and
//		the following disclaimer.
//
//	2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions
//		and the following disclaimer in the documentation and/or other materials provided with the
//		distribution.
//
//	THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR IMPLIED
//	WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
//	FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE FREEBSD PROJECT
//	OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//	CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
//	OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
//	AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
//	NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
//	ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


#import "CCShader_private.h"
#import "ccMacros.h"
#import "Support/CCFileUtils.h"
#import "Support/uthash.h"
#import "Support/OpenGL_Internal.h"
#import "CCRenderer_private.h"
#import "CCTexture_private.h"
#import "CCDirector.h"
#import "CCCache.h"


enum {
	CCAttributePosition,
	CCAttributeTexCoord1,
	CCAttributeTexCoord2,
	CCAttributeColor,
};


const NSString *CCShaderUniformProjection = @"cc_Projection";
const NSString *CCShaderUniformProjectionInv = @"cc_ProjectionInv";
const NSString *CCShaderUniformViewSize = @"cc_ViewSize";
const NSString *CCShaderUniformViewSizeInPixels = @"cc_ViewSizeInPixels";
const NSString *CCShaderUniformTime = @"cc_Time";
const NSString *CCShaderUniformSinTime = @"cc_SinTime";
const NSString *CCShaderUniformCosTime = @"cc_CosTime";
const NSString *CCShaderUniformRandom01 = @"cc_Random01";
const NSString *CCShaderUniformMainTexture = @"cc_MainTexture";


/*
	main texture size points/pixels
*/
static const GLchar *CCShaderHeader =
	"#ifndef GL_ES\n"
	"#define lowp\n"
	"#define mediump\n"
	"#define highp\n"
	"#endif\n\n"
	"uniform highp mat4 cc_Projection;\n"
	"uniform highp mat4 cc_ProjectionInv;\n"
	"uniform highp vec2 cc_ViewSize;\n"
	"uniform highp vec2 cc_ViewSizeInPixels;\n"
	"uniform highp vec4 cc_Time;\n"
	"uniform highp vec4 cc_SinTime;\n"
	"uniform highp vec4 cc_CosTime;\n"
	"uniform highp vec4 cc_Random01;\n\n"
	"uniform lowp sampler2D cc_MainTexture;\n\n"
	"varying lowp vec4 cc_FragColor;\n"
	"varying highp vec2 cc_FragTexCoord1;\n"
	"varying highp vec2 cc_FragTexCoord2;\n\n"
	"// End Cocos2D shader header.\n\n";

static const GLchar *CCVertexShaderHeader =
	"#ifdef GL_ES\n"
	"precision highp float;\n\n"
	"#endif\n\n"
	"attribute highp vec4 cc_Position;\n"
	"attribute highp vec2 cc_TexCoord1;\n"
	"attribute highp vec2 cc_TexCoord2;\n"
	"attribute highp vec4 cc_Color;\n\n"
	"// End Cocos2D vertex shader header.\n\n";

static const GLchar *CCFragmentShaderHeader =
	"#ifdef GL_ES\n"
	"precision lowp float;\n\n"
	"#endif\n\n"
	"// End Cocos2D fragment shader header.\n\n";

static NSString *CCDefaultVShader =
	@"void main(){\n"
	@"	gl_Position = cc_Position;\n"
	@"	cc_FragColor = cc_Color;\n"
	@"	cc_FragTexCoord1 = cc_TexCoord1;\n"
	@"	cc_FragTexCoord2 = cc_TexCoord2;\n"
	@"}\n";

typedef void (* GetShaderivFunc) (GLuint shader, GLenum pname, GLint* param);
typedef void (* GetShaderInfoLogFunc) (GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog);

static BOOL
CCCheckShaderError(GLint obj, GLenum status, GetShaderivFunc getiv, GetShaderInfoLogFunc getInfoLog)
{
	GLint success;
	getiv(obj, status, &success);
	
	if(!success){
		GLint length;
		getiv(obj, GL_INFO_LOG_LENGTH, &length);
		
		char *log = (char *)alloca(length);
		getInfoLog(obj, length, NULL, log);
		
		fprintf(stderr, "Shader compile error for 0x%04X: %s\n", status, log);
		return NO;
	} else {
		return YES;
	}
}

static const GLchar *
CCShaderTypeHeader(GLenum type)
{
	switch(type){
		case GL_VERTEX_SHADER: return CCVertexShaderHeader;
		case GL_FRAGMENT_SHADER: return CCFragmentShaderHeader;
		default: NSCAssert(NO, @"Bad shader type enumeration."); return NULL;
	}
}

static GLint
CompileShader(GLenum type, const char *source)
{
	GLint shader = glCreateShader(type);
	
	const GLchar *sources[] = {
		CCShaderHeader,
		CCShaderTypeHeader(type),
		source,
	};
	
	glShaderSource(shader, 3, sources, NULL);
	glCompileShader(shader);
	
	NSCAssert(CCCheckShaderError(shader, GL_COMPILE_STATUS, glGetShaderiv, glGetShaderInfoLog), @"Error compiling shader");
	
	return shader;
}


@interface CCShaderCache : CCCache @end
@implementation CCShaderCache

-(id)createSharedDataForKey:(id<NSCopying>)key
{
	NSString *shaderName = (NSString *)key;
	
	NSString *fragmentName = [shaderName stringByAppendingPathExtension:@"fsh"];
	NSString *fragmentPath = [[CCFileUtils sharedFileUtils] fullPathForFilename:fragmentName];
	NSAssert(fragmentPath, @"Failed to find '%@'.", fragmentName);
	NSString *fragmentSource = [NSString stringWithContentsOfFile:fragmentPath encoding:NSUTF8StringEncoding error:nil];
	
	NSString *vertexName = [shaderName stringByAppendingPathExtension:@"vsh"];
	NSString *vertexPath = [[CCFileUtils sharedFileUtils] fullPathForFilename:vertexName];
	NSString *vertexSource = (vertexPath ? [NSString stringWithContentsOfFile:vertexPath encoding:NSUTF8StringEncoding error:nil] : CCDefaultVShader);
	
	return [[CCShader alloc] initWithVertexShaderSource:vertexSource fragmentShaderSource:fragmentSource];
}

-(id)createPublicObjectForSharedData:(id)data
{
	return [data copy];
}

@end


@implementation CCShader {
	BOOL _ownsProgram;
}

#if defined(__CC_PLATFORM_IOS)
#define glGenVertexArray glGenVertexArrayOES
#define glBindVertexArray glBindVertexArrayOES
#endif

+(GLuint)createVAOforCCVertexBuffer:(GLuint)vbo elementBuffer:(GLuint)ebo
{
	glPushGroupMarkerEXT(0, "CCShader: Creating vertex buffer");
	
	GLuint vao = 0;
	glGenVertexArrays(1, &vao);
	glBindVertexArray(vao);

	glEnableVertexAttribArray(CCAttributePosition);
	glEnableVertexAttribArray(CCAttributeTexCoord1);
	glEnableVertexAttribArray(CCAttributeTexCoord2);
	glEnableVertexAttribArray(CCAttributeColor);
	
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glVertexAttribPointer(CCAttributePosition, 4, GL_FLOAT, GL_FALSE, sizeof(CCVertex), (void *)offsetof(CCVertex, position));
	glVertexAttribPointer(CCAttributeTexCoord1, 2, GL_FLOAT, GL_FALSE, sizeof(CCVertex), (void *)offsetof(CCVertex, texCoord1));
	glVertexAttribPointer(CCAttributeTexCoord2, 2, GL_FLOAT, GL_FALSE, sizeof(CCVertex), (void *)offsetof(CCVertex, texCoord2));
	glVertexAttribPointer(CCAttributeColor, 4, GL_FLOAT, GL_FALSE, sizeof(CCVertex), (void *)offsetof(CCVertex, color));
	
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);

	glBindVertexArray(0);
	glBindBuffer(GL_ARRAY_BUFFER, 0);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
	
	glPopGroupMarkerEXT();
	
	return vao;
}

#warning TODO error handling
-(NSDictionary *)uniformSettersForProgram:(GLuint)program
{
	NSMutableDictionary *uniformSetters = [NSMutableDictionary dictionary];
	
	glUseProgram(program);
	
	GLint count = 0;
	glGetProgramiv(program, GL_ACTIVE_UNIFORMS, &count);
	
	int textureUnit = 0;
	
	for(int i=0; i<count; i++){
		GLchar cname[256];
		GLsizei length = 0;
		GLsizei size = 0;
		GLenum type = 0;
		
		glGetActiveUniform(program, i, sizeof(cname), &length, &size, &type, cname);
		NSAssert(size == 1, @"Uniform arrays not supported. (yet?)");
		
		NSString *name = @(cname);
		GLint location = glGetUniformLocation(program, cname);
		
		// Setup a block that is responsible for binding that uniform variable's value.
		switch(type){
			case GL_FLOAT: {
				uniformSetters[name] = ^(CCRenderer *renderer, NSNumber *value){
					value = value ?: @0;
					NSAssert([value isKindOfClass:[NSNumber class]], @"Shader uniform '%@' value must be wrapped in a NSNumber.", name);
					
					glUniform1f(location, value.floatValue);
				};
			}; break;
			case GL_FLOAT_VEC2: {
				uniformSetters[name] = ^(CCRenderer *renderer, NSValue *value){
					value = value ?: [NSValue valueWithGLKVector2:GLKVector2Make(0.0f, 0.0f)];
					NSAssert([value isKindOfClass:[NSValue class]], @"Shader uniform '%@' value must be wrapped in a NSValue.", name);
					
					if(strcmp(value.objCType, @encode(GLKVector2)) == 0){
						GLKVector2 v; [value getValue:&v];
						glUniform2f(location, v.x, v.y);
					} else if(strcmp(value.objCType, @encode(CGPoint)) == 0){
						CGPoint v = {}; [value getValue:&v];
						glUniform2f(location, v.x, v.y);
					} else if(strcmp(value.objCType, @encode(CGSize)) == 0){
						CGSize v = {}; [value getValue:&v];
						glUniform2f(location, v.width, v.height);
					} else {
						NSAssert(NO, @"Shader uniformm 'vec2 %@' value must be passed using [NSValue valueWithGLKVector2:], [NSValue valueWithCGPoint:], or [NSValue valueWithCGSize:]", name);
					}
				};
			}; break;
			case GL_FLOAT_VEC3: {
				uniformSetters[name] = ^(CCRenderer *renderer, NSValue *value){
					value = value ?: [NSValue valueWithGLKVector3:GLKVector3Make(0.0f, 0.0f, 0.0f)];
					NSAssert([value isKindOfClass:[NSValue class]], @"Shader uniform '%@' value must be wrapped in a NSValue.", name);
					NSAssert(strcmp(value.objCType, @encode(GLKVector3)) == 0, @"Shader uniformm 'vec3 %@' value must be passed using [NSValue valueWithGLKVector3:]", name);
					
					GLKVector3 v; [value getValue:&v];
					glUniform3f(location, v.x, v.y, v.z);
				};
			}; break;
			case GL_FLOAT_VEC4: {
				uniformSetters[name] = ^(CCRenderer *renderer, id value){
					value = value ?: [NSValue valueWithGLKVector4:GLKVector4Make(0.0f, 0.0f, 0.0f, 1.0f)];
					
					if([value isKindOfClass:[NSValue class]]){
						NSAssert(strcmp([(NSValue *)value objCType], @encode(GLKVector4)) == 0, @"Shader uniformm 'vec4 %@' value must be passed using [NSValue valueWithGLKVector4:].", name);
						
						GLKVector4 v; [value getValue:&v];
						glUniform4f(location, v.x, v.y, v.z, v.w);
					} else if([value isKindOfClass:[CCColor class]]){
						GLKVector4 v = [(CCColor *)value glkVector4];
						glUniform4f(location, v.x, v.y, v.z, v.w);
					} else {
						NSAssert(NO, @"Shader uniformm 'vec4 %@' value must be passed using [NSValue valueWithGLKVector4:] or a CCColor object.", name);
					}
				};
			}; break;
			case GL_FLOAT_MAT4: {
				uniformSetters[name] = ^(CCRenderer *renderer, NSValue *value){
					value = value ?: [NSValue valueWithGLKMatrix4:GLKMatrix4Identity];
					NSAssert([value isKindOfClass:[NSValue class]], @"Shader uniform '%@' value must be wrapped in a NSValue.", name);
					NSAssert(strcmp(value.objCType, @encode(GLKMatrix4)) == 0, @"Shader uniformm 'mat4 %@' value must be passed using [NSValue valueWithGLKMatrix4:]", name);
					
					GLKMatrix4 m; [value getValue:&m];
					glUniformMatrix4fv(location, 1, GL_FALSE, m.m);
				};
			}; break;
			case GL_SAMPLER_2D: {
				uniformSetters[name] = ^(CCRenderer *renderer, CCTexture *texture){
					texture = texture ?: [CCTexture none];
					NSAssert([texture isKindOfClass:[CCTexture class]], @"Shader uniform '%@' value must be a CCTexture object.", name);
					
					// Bind the texture to the texture unit for the uniform.
					glActiveTexture(GL_TEXTURE0 + textureUnit);
					glBindTexture(GL_TEXTURE_2D, texture.name);
				};
				
				// Bind the texture unit at init time.
				glUniform1i(location, textureUnit);
				textureUnit++;
			}; break;
			default: NSAssert(NO, @"Uniform type not supported. (yet?)");
		}
	}
	
	return uniformSetters;
}

-(instancetype)initWithProgram:(GLuint)program uniformSetters:(NSDictionary *)uniformSetters ownsProgram:(BOOL)ownsProgram
{
	if((self = [super init])){
		_program = program;
		_uniformSetters = uniformSetters;
		_ownsProgram = ownsProgram;
	}
	
	return self;
}

-(instancetype)initWithVertexShaderSource:(NSString *)vertexSource fragmentShaderSource:(NSString *)fragmentSource
{
	glPushGroupMarkerEXT(0, "CCShader: Init");
	
	GLuint program = glCreateProgram();
	glBindAttribLocation(program, CCAttributePosition, "cc_Position");
	glBindAttribLocation(program, CCAttributeTexCoord1, "cc_TexCoord1");
	glBindAttribLocation(program, CCAttributeTexCoord2, "cc_TexCoord2");
	glBindAttribLocation(program, CCAttributeColor, "cc_Color");
	
	GLint vshader = CompileShader(GL_VERTEX_SHADER, vertexSource.UTF8String);
	glAttachShader(program, vshader);
	
	GLint fshader = CompileShader(GL_FRAGMENT_SHADER, fragmentSource.UTF8String);
	glAttachShader(program, fshader);
	
	glLinkProgram(program);
	NSCAssert(CCCheckShaderError(program, GL_LINK_STATUS, glGetProgramiv, glGetProgramInfoLog), @"Error linking shader program");
	
	glDeleteShader(vshader);
	glDeleteShader(fshader);
	
	glPopGroupMarkerEXT();
	
	return [self initWithProgram:program uniformSetters:[self uniformSettersForProgram:program] ownsProgram:YES];
}

-(instancetype)initWithFragmentShaderSource:(NSString *)source
{
	return [self initWithVertexShaderSource:CCDefaultVShader fragmentShaderSource:source];
}

- (void)dealloc
{
	CCLOGINFO( @"cocos2d: deallocing %@", self);

	if(_ownsProgram && _program) glDeleteProgram(_program);
}

-(instancetype)copyWithZone:(NSZone *)zone
{
	return [[CCShader allocWithZone:zone] initWithProgram:_program uniformSetters:_uniformSetters ownsProgram:NO];
}

static CCShaderCache *CC_SHADER_CACHE = nil;
static CCShader *CC_SHADER_POS_COLOR = nil;
static CCShader *CC_SHADER_POS_TEX_COLOR = nil;
static CCShader *CC_SHADER_POS_TEXA8_COLOR = nil;

+(void)initialize
{
	CC_SHADER_CACHE = [[CCShaderCache alloc] init];
	
	// Setup the builtin shaders.
	CC_SHADER_POS_COLOR = [[self alloc] initWithVertexShaderSource:CCDefaultVShader fragmentShaderSource:
		@"void main(){gl_FragColor = cc_FragColor;}"];
	
	CC_SHADER_POS_TEX_COLOR = [[self alloc] initWithVertexShaderSource:CCDefaultVShader fragmentShaderSource:
		@"void main(){gl_FragColor = cc_FragColor * texture2D(cc_MainTexture, cc_FragTexCoord1);}"];
	
	CC_SHADER_POS_TEXA8_COLOR = [[self alloc] initWithVertexShaderSource:CCDefaultVShader fragmentShaderSource:
		@"void main(){gl_FragColor = cc_FragColor*texture2D(cc_MainTexture, cc_FragTexCoord1).a;}"];
}

+(instancetype)positionColorShader
{
	return CC_SHADER_POS_COLOR;
}

+(instancetype)positionTextureColorShader
{
	return CC_SHADER_POS_TEX_COLOR;
}

+(instancetype)positionTextureA8ColorShader
{
	return CC_SHADER_POS_TEXA8_COLOR;
}

+(instancetype)shaderNamed:(NSString *)shaderName
{
	return [CC_SHADER_CACHE objectForKey:shaderName];
}

@end
